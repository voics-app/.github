## What and why

<!-- What does this change and why? Link the issue: Closes #123 -->

## Type

- [ ] feat
- [ ] fix
- [ ] refactor / chore / docs / test / ci
- [ ] breaking change (`!` in the commit type)

## Checklist

- [ ] Branch follows git-flow (`feature/*` -> `develop`, `release/*` or `hotfix/*` -> `main`)
- [ ] Commits follow Conventional Commits
- [ ] Tests added or updated first (TDD for domain and application layers)
- [ ] `make lint` and `make test` pass locally
- [ ] No secrets in source; new secrets are listed in `docs/secrets/inventory.yaml`
- [ ] Pinned interfaces (ports, env vars, topics, payloads) unchanged, or the master plan is updated
- [ ] README / ARCHITECTURE.md updated when behaviour or configuration changed
