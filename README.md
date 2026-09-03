# go-bump

[![Actions Status][action-img]][action-url]

[action-img]: https://github.com/bcomnes/go-bump/actions/workflows/test.yml/badge.svg
[action-url]: https://github.com/bcomnes/go-bump/actions/workflows/test.yml

`go-bump` is a GitHub Action wrapper for creating and publishing Go module releases with [`goversion`](https://github.com/bcomnes/goversion).

`goversion` provides the local-first release workflow and owns version updates, the local release commit and tag, atomic Git publication, GitHub Release creation or reuse, moving major action branches, and Go proxy verification.

`go-bump` adapts that workflow to GitHub Actions by translating action inputs into consumer-pinned `goversion` commands and supplying input validation, Git identity, credentials, lifecycle hooks, and outputs.

## Requirements

`go-bump` v1 requires:

- A single Go module at the repository root.
- An attached release branch rather than detached `HEAD`.
- Full Git history and tags.
- Go with tool dependencies enabled.
- `goversion v2.3.0` committed as a Go tool dependency.
- A dedicated `version.go` compatible with `goversion`.
- `contents: write` when publication is enabled.

Nested modules, multi-module repositories, and Go workspaces are not supported initially.

## Local setup

Pin the release tool once and commit the module changes:

```console
go get -tool github.com/bcomnes/goversion/v2@v2.3.0
git add go.mod go.sum
git commit -m "Add goversion v2.3.0 release tool"
```

The equivalent local release flow is:

```console
go tool github.com/bcomnes/goversion/v2 patch
go test ./...
go tool github.com/bcomnes/goversion/v2 publish
```

`go-bump` does not install or upgrade `goversion` automatically.

## Example workflow

```yaml
name: Release

on:
  workflow_dispatch:
    inputs:
      version-type:
        description: Version bump
        required: true
        type: choice
        options:
          - patch
          - minor
          - major
          - premajor
          - preminor
          - prepatch
          - prerelease
          - custom
      new-version:
        description: Explicit semantic version for custom, such as 0.1.0 (no leading v)
        required: false
        type: string

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.repository.default_branch }}
          fetch-depth: 0
          persist-credentials: false

      - uses: actions/setup-go@v5
        with:
          go-version-file: go.mod

      - run: go mod download
      - run: go test ./...

      - id: bump
        uses: bcomnes/go-bump@<immutable-release-ref>
        with:
          version-type: ${{ inputs.version-type }}
          new-version: ${{ inputs.new-version }}
          github-token: ${{ github.token }}
          pre-publish: go test ./...

      - run: echo "Published ${{ steps.bump.outputs.release-tag }}"
```

The initial test run validates the current source.

`pre-publish` validates the exact version commit and tag before `goversion publish` changes remote state.

For a custom release, select `custom` and enter the version without a leading `v`:

```text
0.1.0
```

Do not enter `v0.1.0`; `goversion` adds the `v` prefix to the Git tag automatically.

Use a repository-controlled command only; hook inputs execute trusted shell code.

## Inputs

### Versioning

| Input | Default | Description |
|---|---|---|
| `version-type` | none | `major`, `minor`, `patch`, `premajor`, `preminor`, `prepatch`, `prerelease`, or `custom` |
| `new-version` | none | Explicit version without a leading `v`, such as `0.1.0`, required for `custom` or when `version-type` is omitted |
| `version-file` | `./version.go` | Repository-relative version file |
| `files` | none | Newline-delimited values passed as repeated `goversion -file` flags |
| `bump-files` | none | Newline-delimited values passed as repeated `goversion -bump-file` flags |
| `post-bump` | none | Repository-relative executable passed to `goversion -post-bump` |

`from-git` and `dev` are not action release directives.

Cross-major explicit and prerelease transitions are rejected unless the literal `major` directive can perform the required Go module migration safely.

### Publishing

| Input | Default | Description |
|---|---|---|
| `publish` | `true` | Run `goversion publish` after creating and validating the local release |
| `publish-dry-run` | `false` | Run `goversion publish -dry` without changing remote state |
| `remote` | `origin` | Git remote passed to `goversion publish -remote` |
| `proxy` | `https://proxy.golang.org` | Proxy passed to `goversion publish -proxy` |
| `publish-timeout` | `2m` | Per-command timeout passed to `goversion publish -timeout` |
| `create-release` | `true` | Set to `false` to pass `-no-release` |
| `seed-proxy` | `true` | Set to `false` to pass `-no-proxy` |
| `major-branch` | `false` | After publication, update and push the moving major action branch such as `v1` |

Set `seed-proxy: false` for private modules or releases that must not contact a module proxy.

`major-branch` is intended for repositories that publish GitHub Actions.

It maps directly to `goversion publish -major-branch`.

`goversion` resolves the exact release-tag commit, updates `refs/heads/vN`, and pushes that branch with `--force-with-lease` so concurrent releases are not overwritten silently.

It requires publication but supports `publish-dry-run` through `goversion`'s planned/reused status model.

The consumer's pinned `goversion` must expose the `-major-branch` flag; otherwise `go-bump` fails before mutation with an upgrade command.

Publication is resumable.

Rerunning `goversion publish` reuses matching remote refs and an existing GitHub Release before continuing incomplete work such as proxy verification.

### Identity and hooks

| Input | Default | Description |
|---|---|---|
| `git-username` | `github.actor` | Local release commit author name |
| `git-email` | actor noreply address | Local release commit author email |
| `github-token` | `github.token` | Token used for HTTPS Git authentication and `gh` |
| `pre-publish` | none | Trusted shell command run after local release creation and before publication |
| `post-publish` | none | Trusted shell command run after successful publication handling |

Hooks receive:

- `GOVERSION_OLD_VERSION`
- `GOVERSION_NEW_VERSION`
- `GO_BUMP_TAG`
- `GO_BUMP_COMMIT`
- `GO_BUMP_BRANCH`

GitHub tokens are removed from hook environments.

## Outputs

| Output | Description |
|---|---|
| `old-version` | Version before the release |
| `new-version` | Created release version |
| `release-tag` | Exact `v<version>` tag verified at `HEAD` |
| `release-commit` | Exact release commit SHA |
| `release-branch` | Attached release branch |
| `published` | `true` after successful non-dry publication |
| `publish-dry-run` | `true` after successful publication preflight |
| `major-branch` | Moving major action branch updated by the release, or empty when disabled |

## Self-hosting action release

The pinned `goversion v2.3.0` includes `publish -major-branch`, so `go-bump` can release itself by invoking the checked-out composite action and enabling its moving major branch:

```yaml
- uses: actions/checkout@v4
  with:
    ref: ${{ github.event.repository.default_branch }}
    fetch-depth: 0
    persist-credentials: false

- uses: actions/setup-go@v5
  with:
    go-version-file: go.mod

- run: make all

- id: release
  uses: ./
  with:
    version-type: ${{ inputs.version-type }}
    new-version: ${{ inputs.new-version }}
    github-token: ${{ github.token }}
    pre-publish: make all
    major-branch: true
```

For a release such as `v1.4.2`, consumers can then use:

```yaml
uses: bcomnes/go-bump@v1
```

The exact `v1.4.2` tag remains immutable while the `v1` branch advances to compatible releases.

## Publication behavior

`goversion publish`:

1. Validates the root module, clean worktree, attached branch, version, and local tag.
2. Atomically pushes only incomplete exact branch and tag refs.
3. Creates or reuses a GitHub Release with generated notes when authenticated `gh` is available.
4. Seeds and verifies the module through the configured Go proxy.

Missing or unauthenticated `gh` causes `goversion` to warn and skip the GitHub Release while continuing publication.

Set `create-release: false` to skip that stage intentionally.

An authenticated `gh` operation that fails remains fatal.

## Recovery

A failed local version operation may leave changed files, a commit, or a local tag.

`go-bump` reports state but does not reset or delete release work automatically.

A `pre-publish` failure leaves the local release candidate unpushed for inspection.

A publication failure may occur after public refs or a GitHub Release already exist.

Resume with the same publication settings, for example:

```console
go tool github.com/bcomnes/goversion/v2 publish
```

Never delete or move a published version tag as automated recovery.

## Development

```console
make all
```

This downloads dependencies, builds the small self-version package, runs Go tests, and runs action integration tests against temporary Git repositories.

## License

MIT
