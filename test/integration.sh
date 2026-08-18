#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT=$ROOT/scripts/go-bump.sh
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

new_repo() {
  local name=$1
  local repo=$TMP/$name
  mkdir -p "$repo"
  cp "$ROOT/go.mod" "$ROOT/go.sum" "$repo/"
  cat > "$repo/version.go" <<'GO'
package example

var (
	Version = "0.1.0"
)
GO
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
assert_contains "$TMP/local-release-output" 'published=false'
[[ "$(git -C "$repo" describe --exact-match --tags HEAD)" == 'v0.1.1' ]]
[[ "$(git -C "$repo" log -1 --format=%s)" == '0.1.1' ]]

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

printf 'test: invalid input fails before mutation\n'
repo=$(new_repo invalid-input)
before=$(git -C "$repo" rev-parse HEAD)
if run_action "$repo" PUBLISH=maybe >"$repo/stdout" 2>"$repo/stderr"; then
  printf 'invalid boolean unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(git -C "$repo" rev-parse HEAD)" == "$before" ]]
assert_contains "$repo/stderr" 'publish must be true or false'

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

printf 'test: unavailable major-branch capability fails before mutation\n'
repo=$(new_repo major-branch-capability)
remote=$TMP/major-remote.git
git init --bare "$remote" >/dev/null
git -C "$repo" remote add origin "$remote"
before=$(git -C "$repo" rev-parse HEAD)
if (
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
) >"$repo/stdout" 2>"$repo/stderr"; then
  printf 'unsupported major-branch capability unexpectedly succeeded\n' >&2
  exit 1
fi
[[ "$(git -C "$repo" rev-parse HEAD)" == "$before" ]]
assert_contains "$repo/stderr" 'does not support publish -major-branch'

printf 'all integration tests passed\n'
