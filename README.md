# nitra/actions

Small, public composite actions for GitHub Actions and compatible Forgejo
Actions runners. Every Forgejo API action takes an explicit server URL,
repository, and short-lived token; it never reads a stored credential.

## Forgejo OIDC token

Requests a short-lived OIDC ID token from the current Forgejo Actions job.
The calling workflow must enable OIDC and the runner must provide `curl` and
`jq`:

```yaml
- id: oidc
  uses: nitra/actions/oidc-token@v1
  with:
    audience: my-service

- run: my-client --token "${{ steps.oidc.outputs.token }}"
```

```yaml
enable-openid-connect: true
```

## Release actions

These actions compose a Forgejo release pipeline. They require a runner with
`git`, `curl`, `jq`, and a SHA-256 tool (`sha256sum` or `shasum`).

| Action | Purpose |
| --- | --- |
| `conventional-release-version` | Calculate strict SemVer from conventional commits and Git tags. |
| `git-commit-tag-push` | Optionally commit selected paths, then push a branch and annotated tag. |
| `forgejo-create-draft-release` | Find or create a draft release and return its ID. |
| `forgejo-upload-release-assets` | Upload assets or verify an already uploaded same-named asset by SHA-256. |
| `forgejo-workflow-dispatch` | Dispatch a workflow at a specified ref. |
| `forgejo-publish-release` | Publish a release by tag. |

`conventional-release-version` is read-only and returns `release=false` when
there is no releasable commit. The other release actions mutate Git or Forgejo;
use them only in workflows protected by an appropriately scoped OIDC
integration.

```yaml
- id: version
  uses: nitra/actions/conventional-release-version@v1
  with:
    current-version: 1.2.3

- if: steps.version.outputs.release == 'true'
  uses: nitra/actions/git-commit-tag-push@v1
  with:
    token: ${{ steps.oidc.outputs.token }}
    branch: main
    tag: ${{ steps.version.outputs.tag }}
    paths: Cargo.toml
    commit-message: "chore(release): ${{ steps.version.outputs.tag }}"
```

## Smoke input and output

Checks input and output wiring:

```yaml
- id: smoke
  uses: nitra/actions/smoke-input-output@v1
  with:
    message: hello

- run: test "${{ steps.smoke.outputs.message }}" = hello
```

For production workflows, pin an action to a full commit SHA. `@v1` is a
convenience major-version tag and must only move to compatible releases.

## Versions

This is a monorepo, so one release version covers every action directory.
Publish immutable tags such as `v1.0.0`; then move the mutable `v1` tag only to
backwards-compatible `v1.x.y` releases. Consumers normally use `@v1`, like
`actions/checkout@v6`; security-sensitive workflows may pin the full commit
SHA instead.
