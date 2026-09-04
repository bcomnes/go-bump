# go-bump

[![Actions Status][action-img]][action-url]

[action-img]: https://github.com/bcomnes/go-bump/actions/workflows/test.yml/badge.svg
[action-url]: https://github.com/bcomnes/go-bump/actions/workflows/test.yml

`go-bump` is a GitHub Action wrapper for creating and publishing Go module releases with [`goversion`](https://github.com/bcomnes/goversion).
`goversion` provides the local-first release workflow and owns version updates, the local release commit and tag, atomic Git publication, GitHub Release creation or reuse, moving major action branches, and Go proxy verification.
`go-bump` adapts that workflow to GitHub Actions by translating action inputs into consumer-pinned `goversion` commands and supplying input validation, Git identity, credentials, lifecycle hooks, and outputs.

## Requirements

`go-bump` v1 requires:

- One selected root or nested Go module per action invocation.
- An attached release branch rather than detached `HEAD`.
- Full Git history and tags.
- Go with tool dependencies enabled.
- `goversion v2.4.1` or newer committed as a Go tool dependency in the selected module.
- A dedicated version file compatible with `goversion`.
- `contents: write` when publication is enabled.

Repositories may contain multiple modules, but each invocation versions and publishes only the module selected by `workdir`.
Go workspaces are not used for module selection.

## Local setup

Pin the release tool once and commit the module changes:

```console
go get -tool github.com/bcomnes/goversion/v2@v2.4.1
git add go.mod go.sum
git commit -m "Add goversion v2.4.1 release tool"
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
        uses: bcomnes/go-bump@v0
        with:
          version-type: ${{ inputs.version-type }}
          new-version: ${{ inputs.new-version }}
          github-token: ${{ github.token }}
          pre-publish: go test ./...

      - run: echo "Published ${{ steps.bump.outputs.release-tag }}"
```

The initial test run validates the current source.
`pre-publish` validates the exact version commit and tag before `goversion publish` changes remote state.

For a module in a subdirectory, register `goversion` in that module's `go.mod`, point Go setup at it, and select the module with `workdir`. For example, a module under `tools/widget/` can use:

```yaml
- uses: actions/setup-go@v5
  with:
    go-version-file: tools/widget/go.mod

- uses: bcomnes/go-bump@v0
  with:
    workdir: tools/widget
    version-file: internal/version/version.go
    version-type: patch
    github-token: ${{ github.token }}
    pre-publish: make release-validation
```

The action itself and lifecycle hooks still run from the repository root.
Version files, additional files, bump files, and `post-bump` are resolved relative to `workdir`.
For this example, `goversion` creates and publishes a tag such as `tools/widget/v0.1.1`.

For a custom release, select `custom` and provide an unprefixed semantic version:

```text
0.1.0
```

Do not provide a `v`-prefixed Git tag such as `v0.1.0` or `tools/widget/v0.1.0`.
`goversion` derives the canonical tag from the unprefixed version: `0.1.0` becomes `v0.1.0` for a root module or `tools/widget/v0.1.0` for the nested module above.
Use a repository-controlled command only; hook inputs execute trusted shell code.

## Inputs

### Versioning

| Input | Default | Description |
|---|---|---|
| `version-type` | none | `major`, `minor`, `patch`, `premajor`, `preminor`, `prepatch`, `prerelease`, or `custom` |
| `new-version` | none | Explicit version without a leading `v`, such as `0.1.0`, required for `custom` or when `version-type` is omitted |
| `workdir` | `.` | Repository-relative directory containing the selected module's `go.mod` and pinned `goversion` tool |
| `version-file` | `./version.go` | Version file relative to `workdir` |
| `files` | none | Newline-delimited paths relative to `workdir`, passed as repeated `goversion -file` flags |
| `bump-files` | none | Newline-delimited paths relative to `workdir`, passed as repeated `goversion -bump-file` flags |
| `post-bump` | none | Executable relative to `workdir`, passed to `goversion -post-bump` |

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
| `release-tag` | Exact canonical module tag verified at `HEAD`, such as `v0.1.0` or `go/v0.1.0` |
| `release-commit` | Exact release commit SHA |
| `release-branch` | Attached release branch |
| `published` | `true` after successful non-dry publication |
| `publish-dry-run` | `true` after successful publication preflight |
| `major-branch` | Moving major action branch updated by the release, or empty when disabled |

## Moving major references for GitHub Actions

The `major-branch` feature exists specifically for publishing GitHub Actions that consumers reference as `uses: owner/action@vN`.
Ordinary Go modules do not need a moving major branch and should leave `major-branch` disabled.

Release tags such as `v1.4.2` are immutable.
When a GitHub Action release enables `major-branch`, `goversion` also advances the compatible moving branch, such as `v1`.

Consumers can choose an exact release:

```yaml
uses: bcomnes/go-bump@v1.4.2
```

Or they can receive compatible updates through the moving major branch:

```yaml
uses: bcomnes/go-bump@v1
```

Repository maintainers can find the self-release procedure in [`CONTRIBUTING.md`](CONTRIBUTING.md).

## Publication behavior

`goversion publish`:

1. Validates the selected root or nested module, clean worktree, attached branch, version, and canonical local tag.
2. Atomically pushes only incomplete exact branch and tag refs.
3. Creates or reuses a GitHub Release with generated notes when authenticated `gh` is available.
4. Seeds and verifies the module through the configured Go proxy.

Missing or unauthenticated `gh` causes `goversion` to warn and skip the GitHub Release while continuing publication.
Set `create-release: false` to skip that stage intentionally.
An authenticated `gh` operation that fails remains fatal.

## Recovering a failed publication

`go-bump` does not expose a separate resume mode.
Do not rerun the entire `go-bump` action after it has created a release commit.
A full rerun can calculate the next version instead of resuming the interrupted publication.
Use the consumer-pinned `goversion` tool from the selected module directory to inspect and resume the existing release.

First, fetch the release branch and tags from the repository root:

```console
git fetch --tags origin
git switch <release-branch>
git pull --ff-only origin <release-branch>
```

Check the failed workflow log for the intended version, canonical tag, and commit.
If the exact tag was already pushed, verify that it identifies the branch tip using the reported `release-tag` or `expected-tag` value:

```console
git rev-parse HEAD
git rev-parse <release-tag>^{commit}
```

For example, a module selected with `workdir: go` reports a tag such as `go/v0.1.0`.

If the release commit and tag were created only on the failed runner and were not pushed, change to the selected module directory and recreate that candidate locally with the exact version rather than another relative bump:

```console
cd <workdir>
go tool github.com/bcomnes/goversion/v2 0.1.0
go test ./...
```

Then resume publication directly:

```console
go tool github.com/bcomnes/goversion/v2 publish
```

Use the equivalent publish flags when the action used nondefault settings:

```console
go tool github.com/bcomnes/goversion/v2 publish \
  -remote upstream \
  -proxy https://proxy.example.com \
  -timeout 5m \
  -no-release \
  -no-proxy \
  -major-branch
```

Include only the flags that match the failed action run.
Authenticate Git and `gh` locally before publishing when those stages are enabled.
`goversion publish` reuses matching branch and tag refs and an existing GitHub Release before continuing incomplete stages such as proxy verification or the moving major action branch.
Never delete, move, or recreate a published version tag as automated recovery.

## Development

```console
make all
```

This downloads dependencies, builds the small self-version package, runs Go tests, and runs action integration tests against temporary Git repositories.

## License

MIT
