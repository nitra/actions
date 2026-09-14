# nitra/actions

Small, public composite actions for GitHub Actions and compatible Forgejo
Actions runners.

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
