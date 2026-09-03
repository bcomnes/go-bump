#!/usr/bin/env bash
set -Eeuo pipefail

readonly GOVERSION_TOOL='github.com/bcomnes/goversion/v2'
readonly REQUIRED_GOVERSION='2.3.0'

fail() {
  printf 'go-bump: %s\n' "$*" >&2
  exit 1
}

is_bool() {
  [[ "$1" == 'true' || "$1" == 'false' ]]
}

require_bool() {
  is_bool "$2" || fail "$1 must be true or false, got: $2"
}

version_at_least() {
  local actual=${1#v}
  local required=${2#v}
  local actual_major actual_minor actual_patch required_major required_minor required_patch
  IFS=. read -r actual_major actual_minor actual_patch <<< "$actual"
  IFS=. read -r required_major required_minor required_patch <<< "$required"
  actual_patch=${actual_patch%%-*}
  required_patch=${required_patch%%-*}
  (( actual_major > required_major )) ||
    (( actual_major == required_major && actual_minor > required_minor )) ||
    (( actual_major == required_major && actual_minor == required_minor && actual_patch >= required_patch ))
}

validate_relative_path() {
  local label=$1
  local path=$2

  [[ -n "$path" ]] || fail "$label must not be empty"
  [[ "$path" != /* ]] || fail "$label must be repository-relative: $path"
  [[ "$path" != -* ]] || fail "$label must not begin with a dash: $path"
  [[ "$path" != '..' && "$path" != ../* && "$path" != */../* && "$path" != */.. ]] || fail "$label must not traverse outside the repository: $path"
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || fail "$label must not contain a newline"
}

append_paths() {
  local label=$1
  local flag=$2
  local values=$3
  local path

  while IFS= read -r path || [[ -n "$path" ]]; do
    [[ -z "$path" ]] && continue
    validate_relative_path "$label" "$path"
    VERSION_ARGS+=("$flag" "$path")
  done <<< "$values"
}

read_version() {
  local file=$1
  local version
  version=$(sed -nE 's/.*Version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$file" | sed -n '1p')
  [[ -n "$version" ]] || fail "could not read Version from $file"
  printf '%s\n' "$version"
}

major_of() {
  local version=${1#v}
  if [[ "$version" == 'dev' ]]; then
    printf '0\n'
    return
  fi
  version=${version%%-*}
  version=${version%%+*}
  printf '%s\n' "${version%%.*}"
}

write_output() {
  local name=$1
  local value=$2
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf '%s=%s\n' "$name" "$value" >> "$GITHUB_OUTPUT"
  else
    printf '%s=%s\n' "$name" "$value"
  fi
}

run_hook() {
  local label=$1
  local command=$2
  [[ -z "$command" ]] && return
  printf 'go-bump: running %s\n' "$label"
  env -u GH_TOKEN -u GITHUB_TOKEN -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 bash -c "$command"
}

FAILURE_PHASE='preflight'
TARGET_VERSION=''
RELEASE_TAG=''
PUBLISH_ARGS=()

report_failure() {
  local status=$?
  trap - ERR
  set +e

  printf 'go-bump: failure state\n' >&2
  printf '  phase: %s\n' "$FAILURE_PHASE" >&2
  printf '  branch: %s\n' "$(git symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')" >&2
  printf '  head: %s\n' "$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')" >&2
  [[ -z "$TARGET_VERSION" ]] || printf '  target-version: %s\n' "$TARGET_VERSION" >&2
  if [[ -n "$RELEASE_TAG" ]]; then
    printf '  expected-tag: %s\n' "$RELEASE_TAG" >&2
    local tag_commit
    tag_commit=$(git rev-list -n 1 "$RELEASE_TAG" 2>/dev/null)
    [[ -z "$tag_commit" ]] || printf '  tag-commit: %s\n' "$tag_commit" >&2
  fi
  if [[ -n "$(git status --short 2>/dev/null)" ]]; then
    printf '  worktree:\n' >&2
    git status --short >&2
  else
    printf '  worktree: clean\n' >&2
  fi
  if [[ "$FAILURE_PHASE" == 'publication' && ${#PUBLISH_ARGS[@]} -gt 0 ]]; then
    printf '  resume:' >&2
    printf ' %q' go tool "$GOVERSION_TOOL" "${PUBLISH_ARGS[@]}" >&2
    printf '\n' >&2
  fi
  printf 'go-bump: no commits, tags, or files were rolled back\n' >&2
  exit "$status"
}

VERSION_TYPE=${VERSION_TYPE:-}
NEW_VERSION=${NEW_VERSION:-}
VERSION_FILE=${VERSION_FILE:-./version.go}
FILES=${FILES:-}
BUMP_FILES=${BUMP_FILES:-}
POST_BUMP=${POST_BUMP:-}
PUBLISH=${PUBLISH:-true}
PUBLISH_DRY_RUN=${PUBLISH_DRY_RUN:-false}
REMOTE=${REMOTE:-origin}
PROXY=${PROXY:-https://proxy.golang.org}
PUBLISH_TIMEOUT=${PUBLISH_TIMEOUT:-2m}
CREATE_RELEASE=${CREATE_RELEASE:-true}
SEED_PROXY=${SEED_PROXY:-true}
MAJOR_BRANCH=${MAJOR_BRANCH:-false}
GIT_USERNAME=${GIT_USERNAME:-${GITHUB_ACTOR:-github-actions}}
GIT_EMAIL=${GIT_EMAIL:-${GITHUB_ACTOR:-github-actions}@users.noreply.github.com}
PRE_PUBLISH=${PRE_PUBLISH:-}
POST_PUBLISH=${POST_PUBLISH:-}
GH_TOKEN=${GH_TOKEN:-${GITHUB_TOKEN:-}}

for pair in \
  "publish:$PUBLISH" \
  "publish-dry-run:$PUBLISH_DRY_RUN" \
  "create-release:$CREATE_RELEASE" \
  "seed-proxy:$SEED_PROXY" \
  "major-branch:$MAJOR_BRANCH"; do
  require_bool "${pair%%:*}" "${pair#*:}"
done

if [[ "$PUBLISH" == 'false' ]]; then
  [[ "$PUBLISH_DRY_RUN" == 'false' ]] || fail 'publish-dry-run requires publish to be true'
  [[ "$REMOTE" == 'origin' ]] || fail 'remote cannot be customized when publish is false'
  [[ "$PROXY" == 'https://proxy.golang.org' ]] || fail 'proxy cannot be customized when publish is false'
  [[ "$PUBLISH_TIMEOUT" == '2m' ]] || fail 'publish-timeout cannot be customized when publish is false'
  [[ "$CREATE_RELEASE" == 'true' ]] || fail 'create-release cannot be false when publish is false'
  [[ "$SEED_PROXY" == 'true' ]] || fail 'seed-proxy cannot be false when publish is false'
  [[ "$MAJOR_BRANCH" == 'false' ]] || fail 'major-branch requires publish to be true'
fi

validate_relative_path 'version-file' "$VERSION_FILE"
[[ -n "$REMOTE" && "$REMOTE" != -* && "$REMOTE" != *$'\n'* && "$REMOTE" != *$'\r'* ]] || fail 'remote must be a nonempty Git remote name without line breaks'
[[ -n "$PROXY" && "$PROXY" != *$'\n'* && "$PROXY" != *$'\r'* ]] || fail 'proxy must be nonempty and contain no line breaks'
[[ "$PUBLISH_TIMEOUT" == '0' || "$PUBLISH_TIMEOUT" =~ ^-?[0-9]+(ns|us|µs|ms|s|m|h)([0-9]+(ns|us|µs|ms|s|m|h))*$ ]] || fail "publish-timeout is not a Go duration: $PUBLISH_TIMEOUT"

case "$VERSION_TYPE" in
  major|minor|patch|premajor|preminor|prepatch|prerelease)
    [[ -z "$NEW_VERSION" ]] || fail 'new-version must be empty when version-type is a concrete directive'
    VERSION_ARG=$VERSION_TYPE
    ;;
  custom)
    [[ -n "$NEW_VERSION" ]] || fail 'new-version is required when version-type is custom'
    VERSION_ARG=$NEW_VERSION
    ;;
  '')
    [[ -n "$NEW_VERSION" ]] || fail 'either version-type or new-version is required'
    VERSION_ARG=$NEW_VERSION
    ;;
  *)
    fail "unsupported version-type: $VERSION_TYPE"
    ;;
esac

[[ "$VERSION_ARG" != -* && "$VERSION_ARG" != v* && "$VERSION_ARG" != *[[:space:]]* ]] || fail "invalid version value: $VERSION_ARG"
[[ "$VERSION_ARG" != 'from-git' && "$VERSION_ARG" != 'dev' ]] || fail "$VERSION_ARG is not an action release directive"

command -v git >/dev/null || fail 'git is required'
command -v go >/dev/null || fail 'Go is required'
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || fail 'the current directory is not a Git worktree'
REPO_ROOT_PHYSICAL=$(cd -- "$REPO_ROOT" >/dev/null && pwd -P)
[[ "$REPO_ROOT_PHYSICAL" == "$(pwd -P)" ]] || fail 'go-bump must run from the repository root'
BRANCH=$(git symbolic-ref --quiet --short HEAD) || fail 'an attached release branch is required; check out the intended branch explicitly'
[[ -f "$VERSION_FILE" ]] || fail "version file does not exist: $VERSION_FILE"

for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  [[ ! -e "$(git rev-parse --git-path "$marker")" ]] || fail "Git operation in progress: $marker"
done
[[ ! -d "$(git rev-parse --git-path rebase-merge)" && ! -d "$(git rev-parse --git-path rebase-apply)" ]] || fail 'Git rebase in progress'

TOOL_OUTPUT=$(go tool "$GOVERSION_TOOL" -version 2>/dev/null) || fail "goversion is not registered as a Go tool; run: go get -tool $GOVERSION_TOOL@v$REQUIRED_GOVERSION"
TOOL_VERSION=${TOOL_OUTPUT##* }
version_at_least "$TOOL_VERSION" "$REQUIRED_GOVERSION" || fail "goversion v$REQUIRED_GOVERSION or newer is required, found $TOOL_VERSION; run: go get -tool $GOVERSION_TOOL@v$REQUIRED_GOVERSION"
if [[ "$MAJOR_BRANCH" == 'true' ]]; then
  go tool "$GOVERSION_TOOL" publish -help 2>&1 | grep -F -- '-major-branch' >/dev/null || fail "the pinned goversion does not support publish -major-branch; run: go get -tool $GOVERSION_TOOL@v$REQUIRED_GOVERSION"
fi

REMOTE_URL=''
if [[ "$PUBLISH" == 'true' ]]; then
  REMOTE_URL=$(git remote get-url "$REMOTE" 2>/dev/null) || fail "Git remote does not exist: $REMOTE"
  case "$REMOTE_URL" in
    https://*)
      [[ -n "$GH_TOKEN" ]] || fail 'github-token is required for HTTPS publication'
      ;;
  esac
fi

OLD_VERSION=$(read_version "$VERSION_FILE")
VERSION_ARGS=(-version-file "$VERSION_FILE")
append_paths 'files entry' '-file' "$FILES"
append_paths 'bump-files entry' '-bump-file' "$BUMP_FILES"
if [[ -n "$POST_BUMP" ]]; then
  validate_relative_path 'post-bump' "$POST_BUMP"
  [[ -x "$POST_BUMP" ]] || fail "post-bump must be executable: $POST_BUMP"
  VERSION_ARGS+=(-post-bump "$POST_BUMP")
fi

printf 'go-bump: preflighting goversion %s\n' "$VERSION_ARG"
DRY_OUTPUT=$(env -u GH_TOKEN -u GITHUB_TOKEN go tool "$GOVERSION_TOOL" "${VERSION_ARGS[@]}" -dry "$VERSION_ARG")
TARGET_VERSION=$(sed -nE 's/^New Version:[[:space:]]+//p' <<< "$DRY_OUTPUT" | sed -n '1p')
[[ -n "$TARGET_VERSION" ]] || fail 'could not determine the target version from goversion dry run'

OLD_MAJOR=$(major_of "$OLD_VERSION")
TARGET_MAJOR=$(major_of "$TARGET_VERSION")
if [[ "$OLD_MAJOR" != "$TARGET_MAJOR" && "$VERSION_ARG" != 'major' ]]; then
  fail "goversion v$REQUIRED_GOVERSION only migrates cross-major modules safely for the major directive ($OLD_VERSION -> $TARGET_VERSION)"
fi

printf 'go-bump: creating local release %s\n' "$TARGET_VERSION"
FAILURE_PHASE='local-version'
trap report_failure ERR
git config --local user.name "$GIT_USERNAME"
git config --local user.email "$GIT_EMAIL"
env -u GH_TOKEN -u GITHUB_TOKEN go tool "$GOVERSION_TOOL" "${VERSION_ARGS[@]}" "$VERSION_ARG"
FAILURE_PHASE='local-verification'

ACTUAL_VERSION=$(read_version "$VERSION_FILE")
[[ "$ACTUAL_VERSION" == "$TARGET_VERSION" ]] || fail "version mismatch after goversion: expected $TARGET_VERSION, got $ACTUAL_VERSION"
RELEASE_TAG="v$ACTUAL_VERSION"
RELEASE_COMMIT=$(git rev-parse HEAD)
TAG_COMMIT=$(git rev-list -n 1 "$RELEASE_TAG" 2>/dev/null) || fail "expected release tag was not created: $RELEASE_TAG"
[[ "$TAG_COMMIT" == "$RELEASE_COMMIT" ]] || fail "release tag $RELEASE_TAG does not point to HEAD"
[[ "$(git symbolic-ref --quiet --short HEAD)" == "$BRANCH" ]] || fail 'the current branch changed during versioning'

write_output old-version "$OLD_VERSION"
write_output new-version "$ACTUAL_VERSION"
write_output release-tag "$RELEASE_TAG"
write_output release-commit "$RELEASE_COMMIT"
write_output release-branch "$BRANCH"
write_output published false
write_output publish-dry-run false
write_output major-branch ''

export GOVERSION_OLD_VERSION=$OLD_VERSION
export GOVERSION_NEW_VERSION=$ACTUAL_VERSION
export GO_BUMP_TAG=$RELEASE_TAG
export GO_BUMP_COMMIT=$RELEASE_COMMIT
export GO_BUMP_BRANCH=$BRANCH
FAILURE_PHASE='pre-publish'
run_hook 'pre-publish hook' "$PRE_PUBLISH"

if [[ "$PUBLISH" == 'false' ]]; then
  trap - ERR
  printf 'go-bump: publication disabled; local release is ready\n'
  exit 0
fi

PUBLISH_ARGS=(publish -version-file "$VERSION_FILE" -remote "$REMOTE" -proxy "$PROXY" -timeout "$PUBLISH_TIMEOUT")
[[ "$PUBLISH_DRY_RUN" == 'true' ]] && PUBLISH_ARGS+=(-dry)
[[ "$CREATE_RELEASE" == 'false' ]] && PUBLISH_ARGS+=(-no-release)
[[ "$SEED_PROXY" == 'false' ]] && PUBLISH_ARGS+=(-no-proxy)
[[ "$MAJOR_BRANCH" == 'true' ]] && PUBLISH_ARGS+=(-major-branch)

printf 'go-bump: delegating publication to goversion publish\n'
FAILURE_PHASE='publication'
case "$REMOTE_URL" in
  https://github.com/*|https://*.github.com/*)
    GH_TOKEN="$GH_TOKEN" \
      GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0='credential.helper' \
      GIT_CONFIG_VALUE_0='!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f' \
      go tool "$GOVERSION_TOOL" "${PUBLISH_ARGS[@]}"
    ;;
  git@*|ssh://*)
    printf 'go-bump: using existing SSH credentials for %s; github-token authenticates gh only\n' "$REMOTE" >&2
    GH_TOKEN="$GH_TOKEN" go tool "$GOVERSION_TOOL" "${PUBLISH_ARGS[@]}"
    ;;
  *)
    GH_TOKEN="$GH_TOKEN" go tool "$GOVERSION_TOOL" "${PUBLISH_ARGS[@]}"
    ;;
esac

if [[ "$PUBLISH_DRY_RUN" == 'true' ]]; then
  write_output publish-dry-run true
else
  write_output published true
fi

if [[ "$MAJOR_BRANCH" == 'true' ]]; then
  MAJOR_REF="v$(major_of "$ACTUAL_VERSION")"
  write_output major-branch "$MAJOR_REF"
fi

FAILURE_PHASE='post-publish'
run_hook 'post-publish hook' "$POST_PUBLISH"
trap - ERR
