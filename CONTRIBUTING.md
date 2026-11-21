# Contributing

The contributing guide for every `voics-app` repository lives in the docs
repository: [voics-app/docs/CONTRIBUTING.md](https://github.com/voics-app/docs/blob/main/CONTRIBUTING.md).

It covers the Clean Code rules, Clean Architecture layering, git-flow and the
Conventional Commits format. In short:

- Branch from `develop` as `feature/<repo>-<topic>`; `release/*` and `hotfix/*` go to `main`.
  The `gitflow-guard` check rejects anything else.
- Every commit follows [Conventional Commits](https://www.conventionalcommits.org/).
- Run `make lint` and `make test` before opening a pull request.
