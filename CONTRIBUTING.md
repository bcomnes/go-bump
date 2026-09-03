# Contributing

## Guidelines

- Patches, ideas, and changes are welcome.
- Bug fixes are almost always welcome.
- New features are sometimes welcome:
  - Please open an issue to discuss the idea **before** investing significant time.
  - The proposal may be rejected.
  - If you’d rather skip the discussion and jump straight into implementation, be prepared to maintain a fork if the idea is respectfully declined.
- Please follow the style of the existing code.
- All tests must pass.
- New features or code paths must include tests.
- Aim for 100% test coverage.
- Questions are welcome! However, unless there is an official support contract in place, support is not guaranteed.
- Contributors reserve the right to walk away from the project at any time, with or without notice.

## Development

Run the complete local validation suite with:

```console
make all
```

This builds the repository, runs Go checks, and exercises the action against temporary Git repositories and bare remotes.

## Releasing `go-bump`

This section is for repository maintainers.

The manual [`release.yml`](.github/workflows/release.yml) workflow releases `go-bump` using the checked-out composite action rather than an already published action version.

The workflow:

1. Checks out the attached default branch with complete history.
2. Runs `make all` against the current source.
3. Invokes the local action with `uses: ./`.
4. Runs `make all` again through `pre-publish` against the exact version commit and tag.
5. Delegates Git publication, GitHub Release creation, and proxy verification to `goversion publish`.
6. Enables `major-branch` so `goversion` creates or advances the compatible moving action branch such as `v1`.

For a custom release, enter a version without a leading `v`, such as `0.1.0`.

The exact tag remains immutable while the moving `vN` branch is updated with force-with-lease.

The workflow uses this action configuration:

```yaml
- id: release
  uses: ./
  with:
    version-type: ${{ inputs.version-type }}
    new-version: ${{ inputs.new-version }}
    github-token: ${{ github.token }}
    pre-publish: make all
    major-branch: true
```
