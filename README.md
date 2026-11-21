# voics-app/.github

Org-level repository for the `voics-app` GitHub organization. It holds:

- **Reusable workflows** (`.github/workflows/*.yml`, all `on: workflow_call`) that every Discordy repo calls from its `ci.yml`.
- **Org defaults**: the org profile (`profile/README.md`), issue forms and the PR template (`.github/`), `CODEOWNERS`, a dependabot template (`templates/dependabot.yml`) and a `CONTRIBUTING.md` pointer.

## Reusable workflows

Reference them as `voics-app/.github/.github/workflows/<name>.yml@main`.

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
| `secrets-inventory-check.yml` | Fails when a `secretKeyRef.key` or ExternalSecret key (`secretKey` / `remoteRef.property`) is missing from the secrets inventory | `inventory-path` (`secrets/inventory.yaml`), `inventory-repository` (`voics-app/docs`), `inventory-ref`, `manifests-path` |

`*` = required. Every input carries a description in the workflow file.

`rust`, `elixir` and `node` also accept optional `image-name` and `description` inputs. They are used only for job titles and the job summary, so a caller can pass the same values to the language workflow and to `docker.yml`.

**Common inputs and secrets for the language workflows**
- `services`: a JSON object with the same shape as `jobs.<id>.services`.
- `env`: a JSON object of extra environment variables.
- `system-packages`: apt packages to install before the run.
- `private-deps-token` (secret): a token that can read the private org repos and packages, such as the contracts crate (git dependency) or `@voics-app/*` on GitHub Packages. `node.yml` falls back to the job token for packages.

### Image tags (`docker.yml`)

Images are published as `ghcr.io/voics-app/<image-name>`.

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
    uses: voics-app/.github/.github/workflows/gitflow-guard.yml@main

  rust:
    uses: voics-app/.github/.github/workflows/rust.yml@main
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
    uses: voics-app/.github/.github/workflows/docker.yml@main
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
    uses: voics-app/.github/.github/workflows/elixir.yml@main
    with:
      image-name: gateway
      description: Discordy real-time gateway
      services: '{"valkey": {"image": "valkey/valkey:8", "ports": ["6379:6379"]}}'
      env: '{"VALKEY_URL": "redis://localhost:6379"}'
  docker:
    needs: elixir
    permissions: {contents: read, packages: write, id-token: write}
    uses: voics-app/.github/.github/workflows/docker.yml@main
    with:
      image-name: gateway
      description: Discordy real-time gateway
```

**Multi-component repo** (`voice`: Elixir signaling and Rust SFU):

```yaml
jobs:
  signaling:
    uses: voics-app/.github/.github/workflows/elixir.yml@main
    with: {working-directory: signaling, image-name: voice-signaling, description: Discordy voice signaling}
  sfu:
    uses: voics-app/.github/.github/workflows/rust.yml@main
    with: {working-directory: sfu, image-name: voice-sfu, description: Discordy SFU}
  docker:
    needs: [signaling, sfu]
    strategy:
      matrix:
        component: [signaling, sfu]
    permissions: {contents: read, packages: write, id-token: write}
    uses: voics-app/.github/.github/workflows/docker.yml@main
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
    uses: voics-app/.github/.github/workflows/node.yml@main
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
    uses: voics-app/.github/.github/workflows/release-please.yml@main
  docker:
    needs: release-please
    if: needs.release-please.outputs.release-created == 'true'
    permissions: {contents: read, packages: write, id-token: write}
    uses: voics-app/.github/.github/workflows/docker.yml@main
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
    uses: voics-app/.github/.github/workflows/ghcr-retention.yml@main
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
    uses: voics-app/.github/.github/workflows/secrets-inventory-check.yml@main
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
| Owner's PC (label `karma-pc`) | `scripts/runner.sh up` (adds runners within Docker's CPU/RAM budget) | Docker Desktop; run `scripts/runner.sh down` before shutting the PC off |
| A VM, set up **on the VM itself** (label `vm-<hostname>`) | clone this repo on the VM, `gh auth login` + `gh auth refresh -s admin:org`, then `scripts/runner-vm-bootstrap.sh` (no sudo, no argument), log out/in, `scripts/runner.sh up` | Easiest; `up` switches CI to the VM |
| A VM, managed **from the PC** over SSH (label `vm-<ip>`) | `ssh-copy-id user@vm`, `scripts/runner-vm-bootstrap.sh user@vm`, `scripts/runner.sh up --host user@vm`, `scripts/runner.sh use vm-<ip>` | Any Ubuntu/Debian VM reachable over SSH |
| In-cluster ARC (`discordy`) | named explicitly in a workflow | For jobs that need the cluster network |

How it works:

- **Switching:** the reusable workflows' `runs-on` defaults to `ubuntu-latest`, but follows the caller repository variable `CI_RUNNER` when it is set. `runner.sh use <label>` sets that variable in every repository; `use github` deletes it.
- **Planning first:** `runner.sh preflight [--host user@vm] [--label L] [--count N]` and `up --dry-run` print the same read-only JSON plan. They inspect the Docker daemon's CPU/RAM and every `discordy-runner-*` container across labels and indices, before image builds, pulls, registration tokens or removals. A refused plan changes nothing.
- **Building a runner:** `up --count N` means N total active runners for this label, not container indices 1..N. Existing runner #2 satisfies a requested total of one. An unchanged pool returns before builds, pulls or routing changes; use `use <label>` explicitly to change routing. Missing slots use unused names and preserve stopped containers. Runners use `ghcr.io/actions/actions-runner:2.338.2`, one job each, with the host Docker socket and baked build tools.
- **Capacity:** each job reserves 2 CPUs and 6 GiB RAM, with 1 GiB reserved for the host; swap does not add capacity. The default admits up to three slots within this budget, retaining a larger existing pool only when it fits. Explicit `--count` cannot exceed the remaining budget after other labels. An 8 GiB/4 CPU host admits one; a 24 GiB/6 CPU host admits three. The observed 4 CPU/7.2 GiB CI VM therefore admits one. Already excessive pools or a requested smaller count require manual draining; `up` never shrinks them.
- **Recreation:** explicitly drain and stop the selected runners first. `up --recreate` refuses running/paused/restarting targets and removes only selected stopped containers without `--force`. A runner that starts concurrently makes removal fail instead of being killed. Capacity/inventory is checked again after image preparation and before each addition.
- **Restarts:** the containers have no restart policy, so after a reboot the runners are gone. Run `up` again, or `use github`.
- **Removing runners:** `runner.sh down [--host ...]` deregisters and removes them, and switches back to GitHub if they were active.
- **Checking:** `runner.sh status` shows the active `CI_RUNNER` and the online runners.
- **Requirements:** `gh` with `admin:org` (registration tokens), Docker, and `jq`. `--host` also needs SSH access.

**Windows runner on the owner PC (client installer):** `powershell -File scripts
unner-win.ps1 up` downloads and registers a native runner (label `karma-win`, not a container, so it uses the PC's Node/pnpm/Rust/MSVC toolchain) and sets the client repo variable `WINDOWS_RUNNER=karma-win`. The client `release.yml` Windows job then builds the installer on the PC instead of GitHub's `windows-latest`. `runner-win.ps1 down` removes it and releases fall back to `windows-latest`; `status` shows the state. It does not survive a reboot: run `up` again. While it is down and `WINDOWS_RUNNER` is set, client releases wait in the queue.

**Split by default:** `up` and `use <label>` switch only the heavy repos (api, messages, gateway, voice, client) to self-hosted runners; the light repos (docs, website, contracts, gitops, .github, bots-sdk, admin) keep GitHub-hosted runners within the $15/month budget. Change the set with `SELF_HOSTED_REPOS="api messages" scripts/runner.sh up`. `use github` resets all repos.

**Several VMs:** every machine names its runners `<label>-<machine id>-N`, so names never collide, even when two VMs have the same hostname. Give VMs the same `--label` to make one pool: `scripts/runner.sh up --label vm-pool` on each VM, and jobs go to whichever runner is free. `down` removes only that machine's runners, and switches CI back to GitHub only when no other runner with the label is online.

**Resources per runner (one concurrent job):** budget 2 vCPU and 6 GiB RAM, plus
the shared 1 GiB host reserve, and allow about 40 GB disk per runner. For three
heavy jobs, plan for **6–8 vCPU, 24 GiB RAM and 150 GB SSD**. Rust linking,
testcontainers, image builds and caches are much heavier than an idle runner.

The preflight is conservative admission for a **dedicated CI host**, not a live
pressure controller: it does not measure available RAM, free disk, swap activity
or I/O pressure, and it cannot guarantee job performance. Inspect those before
adding capacity. Serialize `up` commands across operators; an inventory snapshot
is not a distributed lock. No preflight path stops containers or deletes caches.

## CI cache

> Full takeover guide (preinstalled tools, every cache and its key, on/off switches with risks, the "when you change X" checklist, quirks): [docs handbook 12, CI runners and caching](https://github.com/voics-app/docs/blob/develop/handbook/12-ci-runners-and-caching.md).

On self-hosted runners the shared workflows use a persistent cache volume and the toolchains baked into the runner image instead of the GitHub Actions cache (gitops#59, [ADR 0022](https://github.com/voics-app/docs/blob/develop/adr/0022-ci-cache-safety-rules.md)). GitHub-hosted runners are unchanged: parallel `fmt`, `clippy`, `test` jobs and the Actions cache.

| What | Where | Used |
|---|---|---|
| cargo home (registry, git, advisory db) | `/cache/cargo` | every run with the cache on |
| cargo `target/` | `/cache/target/<repo>/<key>/` (key = `Cargo.lock` + `rustc -vV` + toolchain + arch + workdir + `env` input) | pull requests and develop pushes only, one job at a time per key (`flock`, a concurrent job gets a private clean dir) |
| sccache | `/cache/sccache` | same as `target/` |
| pnpm store, corepack | `<work dir>/.pnpm-store` (same mount as the checkout, so pnpm hardlinks instead of copying), `/cache/corepack` | every run with the cache on |
| hex, Elixir `deps/_build` snapshot | `/cache/hex`, `/cache/mixcache/<repo>/<key>/` | hex always; snapshot like `target/` |
| Trivy DB | `/cache/trivy` | every run with the cache on |
| toolchains | in the image: rust (+ clippy, rustfmt), Node 22 and 24, Erlang/OTP 29.1.2 + Elixir 1.20.5, trivy, cosign, sccache, yq | detected and used when the cache is on and the versions match; otherwise the normal setup step installs them (GitHub-hosted runners always do) |
| testcontainers images | pre-pulled by `runner.sh up` (postgres, valkey, scylla, minio, redpanda) | always |

**Self-hosted `rust.yml`** runs one job `fmt + clippy + test` (fmt first, compile once, fail fast). Release builds never reuse a persistent `target/`: pushes to `main`, tags, `release/*`, `hotfix/*` and pull requests into `main` compile from a clean workspace; `docker.yml` image builds compile inside the Dockerfile (no persistent `target/`), reuse the host builder's layer cache on self-hosted runners and use `no-cache` on a cold build; SBOM and cosign only run on main, tags and release versions.

**Switch it off (clean from-scratch build, like GitHub-hosted):**

- everywhere: set the repository or organization variable `CI_CACHE` to `off` (`gh variable set CI_CACHE --body off -R voics-app/<repo>`; delete it or set `on` to switch back on);
- one pull request: add the label `ci-no-cache`, then push a commit (a re-run keeps the old label list);
- automatically: every `schedule` run (weekly, `develop`) is cold, so a cache that hides a breakage is found within a week.

**Tag builds don't repeat the checks.** A `vX.Y.Z` tag points at the merge commit that main's CI already built and tested in full (clean, ADR-0022). The rust/node/elixir workflows start with a small `verified` job on tag pushes: if the main push run of the same commit is green, the checks are skipped and only the image job runs (it builds the version image from the layers main already built). No green main run, or the lookup fails, means the checks run as usual. `scripts/release.sh` tags only after main CI is green. It is resumable: run it again with the same version after a stop and it reuses the open `release/X.Y.Z` PR. A cancelled check is not treated as a failure (it waits for the re-run), and the PR is merged only once every check is green. Callers grant the job `actions: read` (plus `contents: read`, and `packages: read` for node) on the jobs that call these workflows; the org's default token has no `actions` scope, and without it the run fails at startup.

**Elixir is one job** (`<name> / checks`): format, compile with warnings as errors, credo, sobelow, hex.audit, then tests. Deps and the build are set up once instead of twice.

**Clear it:** `scripts/runner.sh cache-clear [--host user@vm] [--label L] [--what all|cargo|target|sccache|pnpm|trivy|mix] [--layers] [--force]`. It refuses while a runner of that label is busy (unless `--force`); `--layers` also prunes the host's Docker build cache. `runner.sh status` prints the volume size. The workflows themselves prune target dirs idle for 7 days and keep the 2 newest per repo. **Disk guard:** under 15 GB free on `/cache` a Rust job first drops every other idle target dir (all repos), and under 8 GB it builds with a clean target. Clean builds (releases, cold runs, low disk) compile into `$RUNNER_TEMP/target`, which the runner wipes after the job, so nothing large stays in the workspace. sccache is capped at 4 GB.

**Rebuild the runners (new toolchain versions):** first inspect the read-only plan,
remove the selected runners from job routing, wait for their jobs to finish, and
stop them explicitly. Then use `scripts/runner.sh up --host user@vm --label L --count N --recreate`
with N inside the reported budget. Restore routing with `use <label>` after
registration. Versions live at the top of `runner.sh`; a workflow requesting
another toolchain installs it. Plain `up` keeps running containers and does not
refresh their toolchains.

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
| `inventory-token` | secrets-inventory-check | Read access to `voics-app/docs` |

All third-party actions are pinned to full commit SHAs. `.github/dependabot.yml` keeps those pins current.

## Pending owner actions

These steps need the GitHub org, so they could not be done from here:

1. Create the `voics-app` org and the private repo `.github`, then push `main` and `develop`. The repo name must be exactly `.github`, both so the org profile shows and so the reusable-workflow refs resolve.
2. Let other repos use these workflows. Because this repo is private, open **Settings → Actions → General → Access** and choose "Accessible from repositories in the `voics-app` organization".
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

## Git hooks

Tests run locally, not in CI. Install [lefthook](https://github.com/evilmartians/lefthook) once and run `make hooks` (or `lefthook install`) to enable the pre-push hook in `lefthook.yml`: it runs this repository's lint and unit tests before every push. CI repeats only the slim gate on pull requests. Skip once with `LEFTHOOK=0 git push`.
