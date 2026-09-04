#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/go-bump.sh

# The suite may run inside go-bump's pre-publish hook, where action inputs are
# exported in the parent environment. Each test supplies its own configuration.
unset VERSION_TYPE NEW_VERSION WORKDIR VERSION_FILE FILES BUMP_FILES POST_BUMP
unset PUBLISH PUBLISH_DRY_RUN REMOTE PROXY PUBLISH_TIMEOUT CREATE_RELEASE SEED_PROXY MAJOR_BRANCH
unset GIT_USERNAME GIT_EMAIL PRE_PUBLISH POST_PUBLISH GH_TOKEN GITHUB_TOKEN

TMP=$(mktemp -d)
TMP=$(CDPATH= cd -- "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

assert_contains() {
  local file=$1
  local expected=$2
  grep -F "$expected" "$file" >/dev/null || {
    printf 'expected %s to contain: %s\n' "$file" "$expected" >&2
    cat "$file" >&2
    exit 1
  }
}

assert_not_contains() {
  local file=$1
  local unexpected=$2
  if grep -F "$unexpected" "$file" >/dev/null; then
    printf 'expected %s not to contain: %s\n' "$file" "$unexpected" >&2
    cat "$file" >&2
    exit 1
  fi
}

assert_failure_unchanged() {
  local repo=$1
  local expected=$2
  shift 2
  local before_head before_refs before_status before_version stderr stdout name
  before_head=$(git -C "$repo" rev-parse HEAD)
  before_refs=$(git -C "$repo" show-ref)
  before_status=$(git -C "$repo" status --porcelain)
  before_version=$(cat "$repo/version.go")
  name=${repo##*/}
  stderr=$TMP/$name-failure-stderr
  stdout=$TMP/$name-failure-stdout
  if run_action "$repo" "$@" >"$stdout" 2>"$stderr"; then
    printf 'expected action failure containing: %s\n' "$expected" >&2
    exit 1
  fi
  assert_contains "$stderr" "$expected"
  [[ "$(git -C "$repo" rev-parse HEAD)" == "$before_head" ]]
  [[ "$(git -C "$repo" show-ref)" == "$before_refs" ]]
  [[ "$(git -C "$repo" status --porcelain)" == "$before_status" ]]
  [[ "$(cat "$repo/version.go")" == "$before_version" ]]
}

new_repo() {
  local name=$1
  local initial_version=${2:-0.1.0}
  local repo=$TMP/$name
  mkdir -p "$repo"
  cp "$ROOT/go.mod" "$ROOT/go.sum" "$repo/"
  printf 'package example\n\nvar (\n\tVersion = "%s"\n)\n' "$initial_version" > "$repo/version.go"
  cat > "$repo/example.go" <<'GO'
package example

func Example() string { return Version }
GO
  git -C "$repo" init -b main >/dev/null
  git -C "$repo" add .
  git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m initial >/dev/null
  printf '%s\n' "$repo"
}

run_action() {
  local repo=$1
  shift
  (
    cd "$repo"
    env \
      VERSION_TYPE=patch \
      PUBLISH=false \
      GIT_USERNAME='Release Bot' \
      GIT_EMAIL='release@example.com' \
      GITHUB_OUTPUT="$TMP/${repo##*/}-output" \
      "$@" \
      "$SCRIPT"
  )
}

printf 'test: local patch release and outputs\n'
repo=$(new_repo local-release)
run_action "$repo"
assert_contains "$TMP/local-release-output" 'old-version=0.1.0'
assert_contains "$TMP/local-release-output" 'new-version=0.1.1'
assert_contains "$TMP/local-release-output" 'release-tag=v0.1.1'
assert_contains "$TMP/local-release-output" 'release-branch=main'
assert_contains "$TMP/local-release-output" "release-commit=$(git -C "$repo" rev-parse HEAD)"
assert_contains "$TMP/local-release-output" 'published=false'
assert_contains "$TMP/local-release-output" 'publish-dry-run=false'
assert_contains "$TMP/local-release-output" 'major-branch='
[[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == 'v0.1.1' ]]
[[ "$(git -C "$repo" log -1 --format=%s)" == '0.1.1' ]]

printf 'test: nested module uses workdir and canonical module tag\n'
repo=$(new_repo nested-module)
mkdir "$repo/go"
mv "$repo/go.mod" "$repo/go.sum" "$repo/version.go" "$repo/example.go" "$repo/go/"
sed -i.bak 's|module github.com/bcomnes/go-bump|module example.com/acme/repo/go|' "$repo/go/go.mod"
rm "$repo/go/go.mod.bak"
printf 'root hook marker\n' >"$repo/root-marker.txt"
git -C "$repo" add .
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m 'move module into go' >/dev/null
remote=$TMP/nested-module.git
git init --bare "$remote" >/dev/null
git -C "$repo" remote add origin "$remote"
run_action "$repo" \
  WORKDIR=go \
  PUBLISH=true \
  CREATE_RELEASE=false \
  SEED_PROXY=false \
  PRE_PUBLISH='test -f root-marker.txt && test "$(git describe --exact-match --tags HEAD)" = go/v0.1.1'
assert_contains "$TMP/nested-module-output" 'new-version=0.1.1'
assert_contains "$TMP/nested-module-output" 'release-tag=go/v0.1.1'
[[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == 'go/v0.1.1' ]]
[[ "$(git --git-dir="$remote" rev-parse refs/tags/go/v0.1.1)" == "$(git -C "$repo" rev-parse HEAD)" ]]

git -C "$repo" remote set-url origin "$TMP/missing/nested-module.git"
if run_action "$repo" WORKDIR=go PUBLISH=true CREATE_RELEASE=false SEED_PROXY=false >"$TMP/nested-failure-stdout" 2>"$TMP/nested-failure-stderr"; then
  printf 'failing nested publication unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$TMP/nested-failure-stderr" 'phase: publication'
assert_contains "$TMP/nested-failure-stderr" 'expected-tag: go/v0.1.2'
assert_contains "$TMP/nested-failure-stderr" 'resume-workdir: go'
assert_contains "$TMP/nested-failure-stderr" 'resume: go tool github.com/bcomnes/goversion/v2 publish'
[[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == 'go/v0.1.2' ]]

printf 'test: workdir validation fails before mutation\n'
repo=$(new_repo invalid-workdir)
assert_failure_unchanged "$repo" 'workdir does not exist or is not a directory' WORKDIR=missing
mkdir "$repo/not-a-module"
assert_failure_unchanged "$repo" 'workdir does not contain go.mod' WORKDIR=not-a-module
ln -s "$TMP" "$repo/outside-workdir"
assert_failure_unchanged "$repo" 'workdir resolves outside the repository' WORKDIR=outside-workdir

printf 'test: initial dev releases normalize to semantic major zero\n'
repo=$(new_repo dev-patch dev)
run_action "$repo"
assert_contains "$TMP/dev-patch-output" 'new-version=0.0.1'

repo=$(new_repo dev-minor dev)
run_action "$repo" VERSION_TYPE=minor
assert_contains "$TMP/dev-minor-output" 'new-version=0.1.0'

repo=$(new_repo dev-custom dev)
run_action "$repo" VERSION_TYPE=custom NEW_VERSION=0.1.0
assert_contains "$TMP/dev-custom-output" 'new-version=0.1.0'

printf 'test: stable, prerelease, and explicit directives\n'
for case in 'minor:0.2.0:0.1.0' 'preminor:0.2.0-0:0.1.0' 'prepatch:0.1.1-0:0.1.0' 'prerelease:0.1.0-1:0.1.0-0'; do
  directive=${case%%:*}
  rest=${case#*:}
  expected=${rest%%:*}
  initial=${rest#*:}
  repo=$(new_repo "directive-$directive" "$initial")
  run_action "$repo" VERSION_TYPE="$directive"
  assert_contains "$TMP/directive-$directive-output" "new-version=$expected"
  [[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == "v$expected" ]]
done
repo=$(new_repo explicit-stable)
run_action "$repo" VERSION_TYPE=custom NEW_VERSION=0.1.2
assert_contains "$TMP/explicit-stable-output" 'new-version=0.1.2'
repo=$(new_repo explicit-prerelease)
run_action "$repo" VERSION_TYPE=custom NEW_VERSION=0.1.1-beta.1
assert_contains "$TMP/explicit-prerelease-output" 'new-version=0.1.1-beta.1'

printf 'test: unsafe cross-major transitions fail before mutation\n'
repo=$(new_repo cross-premajor 0.9.0)
assert_failure_unchanged "$repo" 'only migrates cross-major modules safely for the major directive' VERSION_TYPE=premajor
for version in 1.0.0 1.0.0-beta.1; do
  repo=$(new_repo "cross-${version//./-}" 0.9.0)
  assert_failure_unchanged "$repo" 'only migrates cross-major modules safely for the major directive' VERSION_TYPE=custom NEW_VERSION="$version"
done
repo=$(new_repo cross-down 1.2.3)
assert_failure_unchanged "$repo" 'only migrates cross-major modules safely for the major directive' VERSION_TYPE=custom NEW_VERSION=0.9.0

printf 'test: literal major delegates supported module migration\n'
repo=$(new_repo major-migration 1.2.3)
mkdir "$repo/cmd"
cat >"$repo/cmd/main.go" <<'GO'
package main

import example "github.com/bcomnes/go-bump"

func main() { _ = example.Example() }
GO
git -C "$repo" add cmd/main.go
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m 'add self import' >/dev/null
run_action "$repo" VERSION_TYPE=major
assert_contains "$TMP/major-migration-output" 'new-version=2.0.0'
assert_contains "$repo/go.mod" 'module github.com/bcomnes/go-bump/v2'
assert_contains "$repo/cmd/main.go" 'github.com/bcomnes/go-bump/v2'
[[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == 'v2.0.0' ]]
(cd "$repo" && go test ./...)

printf 'test: hooks validate the candidate without receiving tokens\n'
repo=$(new_repo hooks)
cat > "$repo/post-bump.sh" <<'SH'
#!/bin/sh
set -eu
test -z "${GH_TOKEN:-}"
test -z "${GITHUB_TOKEN:-}"
SH
chmod +x "$repo/post-bump.sh"
git -C "$repo" add post-bump.sh
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m 'add hook' >/dev/null
(
  cd "$repo"
  env \
    VERSION_TYPE=patch \
    POST_BUMP=./post-bump.sh \
    PUBLISH=false \
    GH_TOKEN=secret-token \
    GITHUB_TOKEN=secret-token \
    PRE_PUBLISH='test -z "${GH_TOKEN:-}" && test -z "${GITHUB_TOKEN:-}" && test "$(git describe --exact-match --tags HEAD)" = "v0.1.1" && go test ./...' \
    GIT_USERNAME='Release Bot' \
    GIT_EMAIL='release@example.com' \
    GITHUB_OUTPUT="$TMP/hooks-output" \
    "$SCRIPT"
)

printf 'test: invalid inputs fail before mutation\n'
repo=$(new_repo invalid-input)
assert_failure_unchanged "$repo" 'publish must be true or false' PUBLISH=maybe
for case in \
  'PUBLISH_DRY_RUN=yes:publish-dry-run must be true or false' \
  'CREATE_RELEASE=1:create-release must be true or false' \
  'SEED_PROXY=TRUE:seed-proxy must be true or false' \
  'MAJOR_BRANCH=on:major-branch must be true or false' \
  'PUBLISH_DRY_RUN=true:publish-dry-run requires publish to be true' \
  'REMOTE=upstream:remote cannot be customized when publish is false' \
  'PROXY=example.invalid:proxy cannot be customized when publish is false' \
  'PUBLISH_TIMEOUT=1m:publish-timeout cannot be customized when publish is false' \
  'CREATE_RELEASE=false:create-release cannot be false when publish is false' \
  'SEED_PROXY=false:seed-proxy cannot be false when publish is false' \
  'MAJOR_BRANCH=true:major-branch requires publish to be true'; do
  assignment=${case%%:*}
  expected=${case#*:}
  name=${assignment%%=*}
  value=${assignment#*=}
  safe_name=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
  repo=$(new_repo "invalid-$safe_name-${value//[^[:alnum:]]/-}")
  assert_failure_unchanged "$repo" "$expected" "$name=$value"
done

for case in \
  'VERSION_TYPE=:NEW_VERSION=:either version-type or new-version is required' \
  'VERSION_TYPE=patch:NEW_VERSION=0.2.0:new-version must be empty' \
  'VERSION_TYPE=custom:NEW_VERSION=:new-version is required' \
  'VERSION_TYPE=unknown:NEW_VERSION=:unsupported version-type' \
  'VERSION_TYPE=custom:NEW_VERSION=v0.2.0:invalid version value' \
  'VERSION_TYPE=custom:NEW_VERSION=-0.2.0:invalid version value' \
  'VERSION_TYPE=custom:NEW_VERSION=0.2.0 beta:invalid version value' \
  'VERSION_TYPE=custom:NEW_VERSION=dev:dev is not an action release directive' \
  'VERSION_TYPE=custom:NEW_VERSION=from-git:from-git is not an action release directive'; do
  version_type=${case#*VERSION_TYPE=}
  version_type=${version_type%%:NEW_VERSION=*}
  new_version=${case#*:NEW_VERSION=}
  expected=${new_version#*:}
  new_version=${new_version%%:*}
  repo=$(new_repo "invalid-version-${RANDOM}")
  assert_failure_unchanged "$repo" "$expected" VERSION_TYPE="$version_type" NEW_VERSION="$new_version"
done

repo=$(new_repo invalid-multiline-version)
assert_failure_unchanged "$repo" 'invalid version value' VERSION_TYPE=custom NEW_VERSION=$'0.2.0\nbeta'
for duration in 30 '1 minute' 1x; do
  repo=$(new_repo "invalid-duration-${RANDOM}")
  assert_failure_unchanged "$repo" 'publish-timeout is not a Go duration' PUBLISH=true PUBLISH_TIMEOUT="$duration"
done

printf 'test: missing consumer tool fails with setup guidance\n'
repo=$(new_repo missing-tool)
sed -i.bak '/^tool github.com\/bcomnes\/goversion\/v2$/d' "$repo/go.mod"
rm "$repo/go.mod.bak"
git -C "$repo" add go.mod
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m 'remove tool directive' >/dev/null
assert_failure_unchanged "$repo" 'goversion is not registered in ./go.mod as a Go tool; run from .: go get -tool github.com/bcomnes/goversion/v2@v2.4.1'

printf 'test: older consumer tool fails with pinned upgrade guidance\n'
repo=$(new_repo old-tool)
mkdir "$repo/test-bin"
real_go=$(command -v go)
cat >"$repo/test-bin/go" <<SH
#!/bin/sh
if [ "\${1:-}" = tool ]; then
  case " \$* " in
    *' -version '*)
      echo 'goversion version 2.2.0'
      exit 0
      ;;
  esac
fi
exec "$real_go" "\$@"
SH
chmod +x "$repo/test-bin/go"
git -C "$repo" add test-bin/go
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m 'add test shim' >/dev/null
assert_failure_unchanged "$repo" 'goversion v2.4.1 or newer is required, found 2.2.0; run from .: go get -tool github.com/bcomnes/goversion/v2@v2.4.1' PATH="$repo/test-bin:$PATH"

printf 'test: detached head and Git operation states fail before mutation\n'
repo=$(new_repo detached)
git -C "$repo" checkout --detach >/dev/null 2>&1
assert_failure_unchanged "$repo" 'an attached release branch is required'
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
  safe_marker=$(printf '%s' "$marker" | tr '[:upper:]' '[:lower:]')
  repo=$(new_repo "operation-$safe_marker")
  git_dir=$(git -C "$repo" rev-parse --absolute-git-dir)
  : >"$git_dir/$marker"
  assert_failure_unchanged "$repo" "Git operation in progress: $marker"
done
for marker in rebase-merge rebase-apply; do
  repo=$(new_repo "operation-$marker")
  git_dir=$(git -C "$repo" rev-parse --absolute-git-dir)
  mkdir "$git_dir/$marker"
  assert_failure_unchanged "$repo" 'Git rebase in progress'
done

printf 'test: dirty worktree rejects unlisted files and commits listed files\n'
repo=$(new_repo dirty-unlisted)
printf 'dirty\n' >"$repo/unlisted.txt"
assert_failure_unchanged "$repo" 'working directory is dirty'
repo=$(new_repo dirty-listed)
printf 'before\n' >"$repo/notes.txt"
git -C "$repo" add notes.txt
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m 'add notes' >/dev/null
printf 'after\n' >"$repo/notes.txt"
run_action "$repo" FILES=notes.txt
[[ "$(git -C "$repo" show HEAD:notes.txt)" == 'after' ]]

printf 'test: custom files and paths map to goversion\n'
repo=$(new_repo file-mappings)
mkdir -p "$repo/config"
mv "$repo/version.go" "$repo/config/release.go"
printf 'release 0.1.0\n' >"$repo/notes one.txt"
printf 'release 0.1.0\n' >"$repo/notes two.txt"
printf 'api 0.1.0\n' >"$repo/api-version.txt"
printf 'cli 0.1.0\n' >"$repo/cli-version.txt"
cat >"$repo/update-notes.sh" <<'SH'
#!/bin/sh
set -eu
printf 'updated %s\n' "$GOVERSION_NEW_VERSION" >> 'notes one.txt'
printf 'updated %s\n' "$GOVERSION_NEW_VERSION" >> 'notes two.txt'
SH
chmod +x "$repo/update-notes.sh"
git -C "$repo" add .
git -C "$repo" -c user.name=test -c user.email=test@example.com commit -m 'configure version files' >/dev/null
run_action "$repo" VERSION_FILE=config/release.go FILES=$'notes one.txt\nnotes two.txt' BUMP_FILES=$'api-version.txt\ncli-version.txt' POST_BUMP=./update-notes.sh
assert_contains "$TMP/file-mappings-output" 'new-version=0.1.1'
assert_contains "$repo/api-version.txt" '0.1.1'
assert_contains "$repo/cli-version.txt" '0.1.1'
assert_contains "$repo/notes one.txt" 'updated 0.1.1'
assert_contains "$repo/notes two.txt" 'updated 0.1.1'
for path in /tmp/version.go ../version.go dir/../../version.go -version.go; do
  repo=$(new_repo "invalid-path-${RANDOM}")
  assert_failure_unchanged "$repo" 'version-file must' VERSION_FILE="$path"
done

printf 'test: failed pre-publish preserves local release and leaves remote unchanged\n'
repo=$(new_repo failed-pre-publish)
remote=$TMP/failed-pre-publish.git
git init --bare "$remote" >/dev/null
git -C "$repo" remote add origin "$remote"
if run_action "$repo" PUBLISH=true CREATE_RELEASE=false SEED_PROXY=false PRE_PUBLISH='exit 23' >"$TMP/failed-pre-publish-stdout" 2>"$TMP/failed-pre-publish-stderr"; then
  printf 'failing pre-publish unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$TMP/failed-pre-publish-stderr" 'phase: pre-publish'
assert_contains "$TMP/failed-pre-publish-stderr" 'expected-tag: v0.1.1'
assert_contains "$TMP/failed-pre-publish-stderr" 'no commits, tags, or files were rolled back'
[[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == 'v0.1.1' ]]
[[ -z "$(git --git-dir="$remote" show-ref 2>/dev/null || true)" ]]

printf 'test: publication failure reports a resumable command\n'
repo=$(new_repo failed-publication)
git -C "$repo" remote add origin "$TMP/missing/remote.git"
if run_action "$repo" PUBLISH=true CREATE_RELEASE=false SEED_PROXY=false >"$TMP/failed-publication-stdout" 2>"$TMP/failed-publication-stderr"; then
  printf 'failing publication unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$TMP/failed-publication-stderr" 'phase: publication'
assert_contains "$TMP/failed-publication-stderr" 'resume-workdir: .'
assert_contains "$TMP/failed-publication-stderr" 'resume: go tool github.com/bcomnes/goversion/v2 publish'
[[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == 'v0.1.1' ]]

printf 'test: publication dry-run delegates without changing remote\n'
repo=$(new_repo publish-dry-run)
remote=$TMP/remote.git
git init --bare "$remote" >/dev/null
git -C "$repo" remote add origin "$remote"
(
  cd "$repo"
  env \
    VERSION_TYPE=patch \
    PUBLISH=true \
    PUBLISH_DRY_RUN=true \
    CREATE_RELEASE=false \
    SEED_PROXY=false \
    GH_TOKEN=dummy \
    GIT_USERNAME='Release Bot' \
    GIT_EMAIL='release@example.com' \
    GITHUB_OUTPUT="$TMP/publish-dry-run-output" \
    "$SCRIPT"
)
assert_contains "$TMP/publish-dry-run-output" 'publish-dry-run=true'
[[ -z "$(git --git-dir="$remote" show-ref 2>/dev/null || true)" ]]

printf 'test: custom publication mappings and post-publish ordering\n'
repo=$(new_repo custom-publication)
remote=$TMP/custom-publication.git
git init --bare "$remote" >/dev/null
git -C "$repo" remote add upstream "$remote"
(
  cd "$repo"
  env \
    VERSION_TYPE=patch \
    PUBLISH=true \
    PUBLISH_DRY_RUN=true \
    REMOTE=upstream \
    PROXY=https://proxy.example.invalid \
    PUBLISH_TIMEOUT=-1s \
    CREATE_RELEASE=false \
    SEED_PROXY=false \
    POST_PUBLISH='test -z "${GH_TOKEN:-}" && test -z "${GIT_CONFIG_COUNT:-}" && test "$(git describe --exact-match --tags HEAD)" = v0.1.1' \
    GIT_USERNAME='Release Bot' \
    GIT_EMAIL='release@example.com' \
    GITHUB_OUTPUT="$TMP/custom-publication-output" \
    "$SCRIPT"
)
assert_contains "$TMP/custom-publication-output" 'publish-dry-run=true'
[[ -z "$(git --git-dir="$remote" show-ref 2>/dev/null || true)" ]]

repo=$(new_repo failed-post-publish)
remote=$TMP/failed-post-publish.git
git init --bare "$remote" >/dev/null
git -C "$repo" remote add origin "$remote"
if run_action "$repo" PUBLISH=true CREATE_RELEASE=false SEED_PROXY=false POST_PUBLISH='exit 24' >"$TMP/failed-post-publish-stdout" 2>"$TMP/failed-post-publish-stderr"; then
  printf 'failing post-publish unexpectedly succeeded\n' >&2
  exit 1
fi
assert_contains "$TMP/failed-post-publish-stderr" 'phase: post-publish'
assert_contains "$TMP/failed-post-publish-output" 'published=true'
[[ "$(git --git-dir="$remote" rev-parse refs/heads/main)" == "$(git -C "$repo" rev-parse HEAD)" ]]

printf 'test: publication delegates moving major action branch maintenance\n'
repo=$(new_repo major-branch)
remote=$TMP/major-remote.git
git init --bare "$remote" >/dev/null
git -C "$repo" remote add origin "$remote"
for expected in 0.1.1 0.1.2; do
  (
    cd "$repo"
    env \
      VERSION_TYPE=patch \
      PUBLISH=true \
      CREATE_RELEASE=false \
      SEED_PROXY=false \
      MAJOR_BRANCH=true \
      GIT_USERNAME='Release Bot' \
      GIT_EMAIL='release@example.com' \
      GITHUB_OUTPUT="$TMP/major-branch-output" \
      "$SCRIPT"
  )
  release_commit=$(git -C "$repo" rev-parse "v$expected^{commit}")
  major_commit=$(git --git-dir="$remote" rev-parse 'refs/heads/v0')
  [[ "$major_commit" == "$release_commit" ]]
done
assert_contains "$TMP/major-branch-output" 'major-branch=v0'

printf 'all integration tests passed\n'
