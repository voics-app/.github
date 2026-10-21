# discordy-voics/.github

Org-level repository for the `discordy-voics` GitHub organization. It holds:

- **Reusable workflows** (`.github/workflows/*.yml`, all `on: workflow_call`) that every Discordy repo calls from its `ci.yml`.
- **Org defaults**: the org profile (`profile/README.md`), issue forms and the PR template (`.github/`), `CODEOWNERS`, a dependabot template (`templates/dependabot.yml`) and a `CONTRIBUTING.md` pointer.

## Reusable workflows

Reference them as `discordy-voics/.github/.github/workflows/<name>.yml@main`.

Every workflow takes a `runs-on` input. It defaults to `ubuntu-latest`. You can pass a single label, or a JSON array such as `'["self-hosted","discordy"]'` for the in-cluster ARC runners.

| Workflow | What it does | Key inputs |
|---|---|---|
| `rust.yml` | `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, `cargo audit` (parallel jobs) | `working-directory`, `toolchain` (1.99), `clippy-args`, `test-args`, `audit`, `audit-args`, `system-packages`, `services`, `env` |
| `elixir.yml` | `mix format --check-formatted`, `compile --warnings-as-errors`, `credo`, `sobelow`, `hex.audit`; `mix test` with service containers | `working-directory`, `elixir-version` (1.20), `otp-version` (29), `credo-args`, `sobelow`, `sobelow-args`, `test-args`, `services`, `env` |
| `node.yml` | `pnpm install --frozen-lockfile`, lint, typecheck, test, `pnpm audit --prod` | `working-directory`, `node-version` (24), `pnpm-version` (10, ignored when `packageManager` is set), `lint-script`, `typecheck-script`, `test-script` (`""` skips a step), `audit-level` (critical), `npm-scope`, `services`, `env` |
| `docker.yml` | buildx; local build and Trivy scan (fails on CRITICAL); push to GHCR with OCI labels; syft SBOM (artifact plus attestation); cosign keyless signature | `image-name`*, `description`*, `context`, `dockerfile`, `target`, `build-args`, `platforms`, `version`, `push`, `trivy-severity`, `trivy-ignore-unfixed` |
| `release-please.yml` | Runs release-please in manifest mode: release PR, `vX.Y.Z` tag, CHANGELOG, GitHub Release | `target-branch`, `config-file`, `manifest-file`; outputs `release-created`, `tag-name`, `version` |
| `gitflow-guard.yml` | Fails PRs that break git-flow (see below) | `main-sources`, `develop-sources` (space separated globs) |
| `ghcr-retention.yml` | Keeps all stable versions and the newest N prereleases per package; deletes older prereleases and their cosign tags | `packages`*, `keep-prereleases` (5), `dry-run`, `owner` |
| `secrets-inventory-check.yml` | Fails when a `secretKeyRef.key` or ExternalSecret key (`secretKey` / `remoteRef.property`) is missing from the secrets inventory | `inventory-path` (`secrets/inventory.yaml`), `inventory-repository` (`discordy-voics/docs`), `inventory-ref`, `manifests-path` |

`*` = required. Every input carries a description in the workflow file.

`rust`, `elixir` and `node` also accept optional `image-name` and `description` inputs. They are used only for job titles and the job summary, so a caller can pass the same values to the language workflow and to `docker.yml`.

**Common inputs and secrets for the language workflows**
- `services`: a JSON object with the same shape as `jobs.<id>.services`.
- `env`: a JSON object of extra environment variables.
- `system-packages`: apt packages to install before the run.
- `private-deps-token` (secret): a token that can read the private org repos and packages, such as the contracts crate (git dependency) or `@discordy-voics/*` on GitHub Packages. `node.yml` falls back to the job token for packages.

### Image tags (`docker.yml`)

Images are published as `ghcr.io/discordy-voics/<image-name>`.

| Ref | Tags | Pushed |
|---|---|---|
| `develop` | `X.Y.Z-dev.<run_number>` | yes |
| `release/*`, `hotfix/*` | `X.Y.Z-rc.<run_number>` | yes |
| tag `vX.Y.Z` | `X.Y.Z`, `X.Y`, `latest` | yes |
| tag `vX.Y.Z-<pre>` | `X.Y.Z-<pre>` | yes |
| `version: X.Y.Z` input | `X.Y.Z`, `X.Y`, `latest` | yes |
| anything else, and all pull requests | `X.Y.Z-ci.<run_number>` | no (build and scan only) |

Where `X.Y.Z` comes from:
- From the branch name, for `release/X.Y.Z` and `hotfix/X.Y.Z`.
- Otherwise from `.release-please-manifest.json` (key `.`).

OCI labels set on every image: `title`, `description`, `source`, `version`, `revision`, `licenses=UNLICENSED` and `created`.

Callers must grant `contents: read`, `packages: write` and `id-token: write`. The `id-token` permission is what cosign keyless signing needs.

### git-flow rules (`gitflow-guard.yml`)

| PR into | Allowed source branches |
|---|---|
| `main` | `release/*`, `hotfix/*`, `release-please--*` |
| `develop` | `feature/*`, `release/*`, `hotfix/*`, `dependabot/*` |
| anything else | not checked |

`release-please--*` is allowed into `main` because release-please opens its release PR from that branch. Make `gitflow-guard` a required status check.

### Secrets inventory format

The check accepts any YAML schema: a key counts as listed when it appears anywhere in the inventory, either as a mapping key or as a scalar value. The recommended shape is:

```yaml
secrets:
  - name: DATABASE_URL
    services: [api]
    source: github-org-secret
```

## Example callers

**Rust service** (`api/.github/workflows/ci.yml`; `messages` is the same):

```yaml
name: ci
on:
  push:
    branches: [main, develop, "release/**", "hotfix/**", "feature/**"]
    tags: ["v*"]
  pull_request:

permissions:
  contents: read

jobs:
  gitflow:
    if: github.event_name == 'pull_request'
    uses: discordy-voics/.github/.github/workflows/gitflow-guard.yml@main

  rust:
    uses: discordy-voics/.github/.github/workflows/rust.yml@main
    with:
      image-name: api
      description: Discordy REST API
      services: |
        {"postgres": {"image": "postgres:17", "env": {"POSTGRES_PASSWORD": "postgres"},
                      "ports": ["5432:5432"],
                      "options": "--health-cmd pg_isready --health-interval 5s --health-retries 10"}}
      env: '{"DATABASE_URL": "postgres://postgres:postgres@localhost:5432/postgres"}'
    secrets:
      private-deps-token: ${{ secrets.DEPS_TOKEN }}

  docker:
    needs: rust
    permissions:
      contents: read
      packages: write
      id-token: write
    uses: discordy-voics/.github/.github/workflows/docker.yml@main
    with:
      image-name: api
      description: Discordy REST API
    secrets:
      build-secrets: |
        gh_token=${{ secrets.DEPS_TOKEN }}
```

**Elixir service** (`gateway`):

```yaml
jobs:
  elixir:
    uses: discordy-voics/.github/.github/workflows/elixir.yml@main
    with:
      image-name: gateway
      description: Discordy real-time gateway
      services: '{"valkey": {"image": "valkey/valkey:8", "ports": ["6379:6379"]}}'
      env: '{"VALKEY_URL": "redis://localhost:6379"}'
  docker:
    needs: elixir
    permissions: {contents: read, packages: write, id-token: write}
    uses: discordy-voics/.github/.github/workflows/docker.yml@main
    with:
      image-name: gateway
      description: Discordy real-time gateway
```

**Multi-component repo** (`voice`: Elixir signaling and Rust SFU):

```yaml
jobs:
  signaling:
    uses: discordy-voics/.github/.github/workflows/elixir.yml@main
    with: {working-directory: signaling, image-name: voice-signaling, description: Discordy voice signaling}
  sfu:
    uses: discordy-voics/.github/.github/workflows/rust.yml@main
    with: {working-directory: sfu, image-name: voice-sfu, description: Discordy SFU}
  docker:
    needs: [signaling, sfu]
    strategy:
      matrix:
        component: [signaling, sfu]
    permissions: {contents: read, packages: write, id-token: write}
    uses: discordy-voics/.github/.github/workflows/docker.yml@main
    with:
      image-name: voice-${{ matrix.component }}
      description: Discordy voice ${{ matrix.component }}
      context: ${{ matrix.component }}
      dockerfile: ${{ matrix.component }}/Dockerfile
```

**Node project** (`client`, `contracts`, `bots-sdk`):

```yaml
jobs:
  node:
    uses: discordy-voics/.github/.github/workflows/node.yml@main
    with:
      image-name: client
      description: Discordy desktop client
      system-packages: xvfb
```

**Release on `main`**: release-please, then publish the stable image. A tag created with `GITHUB_TOKEN` does not trigger other workflows, so the next job chains on the output instead:

```yaml
name: release
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  release-please:
    permissions: {contents: write, pull-requests: write, issues: write}
    uses: discordy-voics/.github/.github/workflows/release-please.yml@main
  docker:
    needs: release-please
    if: needs.release-please.outputs.release-created == 'true'
    permissions: {contents: read, packages: write, id-token: write}
    uses: discordy-voics/.github/.github/workflows/docker.yml@main
    with:
      image-name: api
      description: Discordy REST API
      version: ${{ needs.release-please.outputs.version }}
```

**GHCR retention** (scheduled from one repo, e.g. `gitops`):

```yaml
on:
  schedule: [{cron: "0 3 * * 1"}]
  workflow_dispatch:
jobs:
  retention:
    permissions: {packages: write}
    uses: discordy-voics/.github/.github/workflows/ghcr-retention.yml@main
    with:
      packages: api messages gateway voice-signaling voice-sfu admin admin-bff
      keep-prereleases: 5
    secrets:
      token: ${{ secrets.GHCR_ADMIN_TOKEN }}
```

**Secrets inventory** (`gitops`):

```yaml
jobs:
  secrets-inventory:
    uses: discordy-voics/.github/.github/workflows/secrets-inventory-check.yml@main
    with:
      manifests-path: .
      inventory-path: secrets/inventory.yaml
    secrets:
      inventory-token: ${{ secrets.DOCS_READ_TOKEN }}
```

## CI runners

All shared workflows run on **GitHub-hosted `ubuntu-latest`** by default. When the GitHub Free minutes run low, you can switch every repository to self-hosted runners on the owner's PC or on a VM, and back, with a single command. Jobs that name a runner explicitly keep it: `discordy` (the in-cluster ARC runners, used for secrets-sync and minio-publish) and `windows-latest` (the installer build).

| Where jobs run | Switch with | Notes |
|---|---|---|
| GitHub-hosted (default) | `scripts/runner.sh use github` | Costs Actions minutes; private repos get 2 vCPU / 7 GB / 14 GB SSD |
| Owner's PC (label `karma-pc`) | `scripts/runner.sh up` (starts 3 containers and switches) | Docker Desktop; run `scripts/runner.sh down` before shutting the PC off |
| A VM, set up **on the VM itself** (label `vm-<hostname>`) | clone this repo on the VM, `gh auth login` + `gh auth refresh -s admin:org`, then `scripts/runner-vm-bootstrap.sh` (no sudo, no argument), log out/in, `scripts/runner.sh up` | Easiest; `up` switches CI to the VM |
| A VM, managed **from the PC** over SSH (label `vm-<ip>`) | `ssh-copy-id user@vm`, `scripts/runner-vm-bootstrap.sh user@vm`, `scripts/runner.sh up --host user@vm`, `scripts/runner.sh use vm-<ip>` | Any Ubuntu/Debian VM reachable over SSH |
| In-cluster ARC (`discordy`) | named explicitly in a workflow | For jobs that need the cluster network |

How it works:

- **Switching:** the reusable workflows' `runs-on` defaults to `ubuntu-latest`, but follows the caller repository variable `CI_RUNNER` when it is set. `runner.sh use <label>` sets that variable in every repository; `use github` deletes it.
- **Building a runner:** `runner.sh up` starts `--count` (default 3) containers of `ghcr.io/actions/actions-runner:2.338.0`, one job each. They register at org level with the label, mount the host's Docker socket for image builds, and install the base packages `ubuntu-latest` ships (`libatomic1`, build tools, cmake, clang, jq).
- **Restarts:** the containers have no restart policy, so after a reboot the runners are gone. Run `up` again, or `use github`.
- **Removing runners:** `runner.sh down [--host ...]` deregisters and removes them, and switches back to GitHub if they were active.
- **Checking:** `runner.sh status` shows the active `CI_RUNNER` and the online runners.
- **Requirements:** `gh` with `admin:org` (registration tokens), Docker, and `jq`. `--host` also needs SSH access.

**Several VMs:** every machine names its runners `<label>-<machine id>-N`, so names never collide, even when two VMs have the same hostname. Give VMs the same `--label` to make one pool: `scripts/runner.sh up --label vm-pool` on each VM, and jobs go to whichever runner is free. `down` removes only that machine's runners, and switches CI back to GitHub only when no other runner with the label is online.

**Resources per runner (one concurrent job):** 2 vCPU, 6–8 GB RAM, about 40 GB disk. Rust builds (api, messages, sfu, native crypto) are the heaviest; docker image builds and caches need the disk. A VM for 3 runners therefore needs about **6–8 vCPU, 16–24 GB RAM and 150 GB disk** (SSD preferred). An idle runner uses about 100 MB RAM.

## Local development

Only Docker is needed. Both targets run in containers.

| Command | What it does |
|---|---|
| `make lint` | `actionlint` (`rhysd/actionlint:1.7.12`) over every workflow, including shellcheck and pyflakes on the embedded scripts |
| `make test` | Unit tests (`tests/test_workflows.py`) that execute the embedded scripts: tag derivation, git-flow rules, retention selection against a fake `gh`, and the inventory check |

On Windows without `make`, run the `docker run` commands from the `Makefile` in Git Bash. Prefix them with `MSYS_NO_PATHCONV=1` and use `$(pwd -W)` as the volume source.

### Configuration

This repository reads no environment variables. Workflows are configured only through their inputs and secrets:

| Secret (caller side) | Used by | Purpose |
|---|---|---|
| `private-deps-token` | rust, elixir, node | Read access to private org repos and packages |
| `build-secrets` | docker | BuildKit secrets, `id=value` per line |
| `token` | release-please | PAT or App token, so release tags trigger workflows |
| `token` | ghcr-retention | `read:packages` + `delete:packages` |
| `inventory-token` | secrets-inventory-check | Read access to `discordy-voics/docs` |

All third-party actions are pinned to full commit SHAs. `.github/dependabot.yml` keeps those pins current.

## Pending owner actions

These steps need the GitHub org, so they could not be done from here:

1. Create the `discordy-voics` org and the private repo `.github`, then push `main` and `develop`. The repo name must be exactly `.github`, both so the org profile shows and so the reusable-workflow refs resolve.
2. Let other repos use these workflows. Because this repo is private, open **Settings → Actions → General → Access** and choose "Accessible from repositories in the `discordy-voics` organization".
3. Create the org secrets that callers pass in:
   - `DEPS_TOKEN`: fine-grained, read access to repo contents and packages.
   - `DOCS_READ_TOKEN`: read access to `docs`.
   - `GHCR_ADMIN_TOKEN`: `read:packages` + `delete:packages`.
   - Optionally a release-please App or PAT token.
4. After each image's first push, give its repository **Admin** access to the GHCR package under Package settings, so the job token can push and the retention job can delete.
5. Make `gitflow-guard` and `ci` required status checks in each repo.
6. Do this repo's `main` release through a `release/0.1.0` PR. Callers reference `@main`, so the workflows are not usable until `main` contains them.

## Notes

The working branch is `feature/github-bootstrap`, not `feature/.github-bootstrap`: git rejects ref components that start with a dot.
