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

## Definition of Done

- [ ] Docs repo updated (runbooks, ADRs, specs, service docs; ops portal for operator tools) - link the docs PR
- [ ] Platform / CI-CD change: Terraform, bootstrap scripts, `env.sh`, cluster-config and env overlays (production + dev), Cloudflare host lists and secrets inventory updated so new environments get it
- [ ] Verified (tests, live/e2e check or Flux rollout) and the issue gets a closing comment that says how
