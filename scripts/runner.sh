#!/usr/bin/env bash
# Self-hosted GitHub Actions runners for discordy-voics, on the owner's PC or on any Linux VM with Docker.
# Linux workflows default to the existing vm-runner pool; CI_RUNNER can select another self-hosted label.
# A stopped pool leaves jobs queued instead of falling back to GitHub-hosted runners.
#
#   scripts/runner.sh up     [--host user@vm] [--count N] [--label L]   start N runner containers (default 3)
#   scripts/runner.sh down   [--host user@vm] [--label L]               deregister and remove them
#   scripts/runner.sh use    <label>                                    switch selected repos' CI_RUNNER
#   scripts/runner.sh status [--host user@vm] [--label L]
#   scripts/runner.sh cache-clear [--host user@vm] [--label L] [--what all|cargo|target|sccache|pnpm|trivy|mix]
#                                 [--layers] [--force]   wipe the persistent CI cache (README "CI cache")
#
# Every runner container mounts the persistent volume discordy-ci-cache-<label> at /cache (cargo home, per-repo
# cargo target dirs, sccache, pnpm store, hex/mix, Trivy DB), so caches survive container recreation. The
# image also carries the toolchains (rust, node 22/24, trivy, cosign, sccache, yq); the shared workflows detect
# and use them and skip their setup steps (switch everything off with the CI_CACHE=off variable).
# Each runner's work dir is /srv/discordy-runner/<container>/_work at the same path on the host, so workflows can
# bind-mount $GITHUB_WORKSPACE into containers they start on the host's Docker.
#
# Without --host the runners run on this machine's Docker (label karma-pc). With --host they run on the
# VM's Docker over SSH (label vm-<host>, override with --label); prepare a fresh VM once with
# scripts/runner-vm-bootstrap.sh user@vm. `up` does not switch CI_RUNNER by itself except for the PC
# (backwards compatible with pc-runner.sh); use `use <label>` to send jobs to a VM.
#
# Needs: docker CLI, gh with admin:org (registration tokens), ssh access for --host.
set -euo pipefail
export MSYS_NO_PATHCONV=1
for d in /c/Users/*/AppData/Local/Microsoft/WinGet/Packages/jqlang.jq_*; do [[ -d "$d" ]] && PATH="$PATH:$d"; done
command -v jq >/dev/null || { echo "jq is required"; exit 1; }
ORG=discordy-voics
IMAGE=ghcr.io/actions/actions-runner:2.338.2   # bump on new runner releases: a self-updated runner can have a broken externals/node24 npm (gitops#63)
# The runner image is minimal; ubuntu-latest ships these (pnpm needs libatomic1, Rust/native builds the rest).
PACKAGES="gettext-base libatomic1 build-essential pkg-config libssl-dev cmake clang unzip zstd jq python3 python3-yaml git curl ca-certificates xz-utils"
# Toolchains baked into the runner image (the shared workflows detect-and-skip their setup steps for these).
RUST_TOOLCHAINS="1.99"
NODE_MAJORS="22 24"
SCCACHE_VERSION=0.10.0
COSIGN_VERSION=v3.0.6
COSIGN_SHA256=c956e5dfcac53d52bcf058360d579472f0c1d2d9b69f55209e256fe7783f4c74
# Erlang/OTP and Elixir: the same hex.pm builds erlef/setup-beam installs on GitHub-hosted runners (elixir.yml
# uses these when they match its otp-version/elixir-version inputs and runs setup-beam otherwise).
OTP_VERSION=29.1.2
OTP_SHA256=2cfca446976fc61962585a1c77e5d11ddb6f5fed83e84668a2c4acfaad60d22e
ELIXIR_VERSION=1.20.5
ELIXIR_SHA256=f424d6f0bb710a1d4898f2645d8ad6cab3f5eab8d71848c0dda2579d3a8e8a06
# Container images the testcontainers suites start (pulled on `up` so tests do not wait for the registry).
PREPULL_IMAGES="postgres:16-alpine postgres:17-alpine valkey/valkey:8-alpine scylladb/scylla:2025.1 pgsty/minio:RELEASE.2026-08-04T00-00-00Z docker.redpanda.com/redpandadata/redpanda:v24.2.7 docker.redpanda.com/redpandadata/redpanda:v25.1.1"
REPOS=(api messages gateway voice admin client website gitops docs contracts .github bots-sdk)
# By default switch every repository; SELF_HOSTED_REPOS can explicitly narrow the target set.
read -ra SELF_HOSTED <<< "${SELF_HOSTED_REPOS:-${REPOS[*]}}"

cmd="${1:-status}"; shift || true
HOST=""; COUNT=3; LABEL=""; WHAT=all; LAYERS=0; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
    --what) WHAT="$2"; shift 2 ;;
    --layers) LAYERS=1; shift ;;
    --force) FORCE=1; shift ;;
    *) TARGET="$1"; shift ;;
  esac
done
if [[ -n "$HOST" ]]; then
  export DOCKER_HOST="ssh://$HOST"
  LABEL="${LABEL:-vm-$(echo "${HOST#*@}" | tr '.' '-')}"
elif [[ "$(uname -s)" == Linux ]]; then
  # Running directly on a Linux VM: local Docker, label after the machine.
  LABEL="${LABEL:-vm-$(hostname -s)}"
else
  LABEL="${LABEL:-${PC_RUNNER_LABEL:-karma-pc}}"
fi
CONTAINER="discordy-runner-$LABEL"
# Persistent host cache shared by all runner containers of this label (cargo registry/git, sccache, pnpm
# store, hex/mix). A named volume survives container recreation (`down` + `up`); remove it explicitly with
# `docker volume rm $CACHE_VOLUME` to reset caches. Mounted at /cache; see the `up` command.
CACHE_VOLUME="discordy-ci-cache-$LABEL"
# Runner NAMES must be unique across machines (down removes by name),
# while several machines may share one LABEL to form a pool. Names get a short id of this machine.
if [[ -n "$HOST" ]]; then
  NODE="$(ssh "$HOST" 'cat /etc/machine-id 2>/dev/null || hostname' | tr -dc 'a-z0-9' | cut -c1-6)"
elif [[ -r /etc/machine-id ]]; then
  NODE="$(tr -dc 'a-z0-9' </etc/machine-id | cut -c1-6)"
else
  NODE="$(hostname | tr 'A-Z' 'a-z' | tr -dc 'a-z0-9' | cut -c1-6)"
fi
PREFIX="$LABEL-$NODE"
# Jobs start sibling containers on the host's Docker (testcontainers) and reach them on mapped ports:
# on a Linux VM the runner shares the host network, so "localhost" works; on Docker Desktop the
# containers are reached through host.docker.internal.
if [[ -n "$HOST" || "$(uname -s)" == Linux ]]; then
  NETWORK_ARGS="--network host"
else
  NETWORK_ARGS="--add-host host.docker.internal:host-gateway -e TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal"
fi

# Works on old gh versions too (gh variable get is recent); empty when the variable is not set.
get_runner_var() { local v; v="$(gh api "repos/$ORG/api/actions/variables/CI_RUNNER" -q .value 2>/dev/null)" && printf %s "$v" || true; }
runners_json() { gh api --paginate "orgs/$ORG/actions/runners?per_page=100" -q ".runners[]"; }
set_runner_var() {
  local targets=("${SELF_HOSTED[@]}")
  for r in "${targets[@]}"; do
    gh variable set CI_RUNNER -R "$ORG/$r" --body "$1" >/dev/null
  done
  echo "CI_RUNNER -> $1 in ${#targets[@]} repos (${targets[*]})"
}

case "$cmd" in
  up)
    # Never replace a running or stopped registration implicitly. Existing containers
    # must be retired deliberately before creating this pool again.
    for i in $(seq 1 "$COUNT"); do
      c="$CONTAINER-$i"
      if docker container inspect "$c" >/dev/null 2>&1; then
        echo "container $c already exists; retain it or remove the pool explicitly before up" >&2
        exit 1
      fi
    done
    echo "Starting $COUNT runner(s) with label $LABEL (first run downloads the image; each runner installs build packages, 2-5 min)"
    # Build packages into a local image once (cached afterwards), instead of apt-get in every container.
    LOCAL_IMAGE="discordy-actions-runner:${IMAGE##*:}"
    echo "Building $LOCAL_IMAGE (first time takes a few minutes; cached afterwards)"
    # Toolchains (rust, node, trivy, cosign, sccache) are baked in too: the shared workflows detect them and skip
    # their setup steps. A failed build keeps the previous image (the inspect below only checks it exists).
    docker build --progress=plain -t "$LOCAL_IMAGE" \
      --build-arg BASE="$IMAGE" --build-arg PACKAGES="$PACKAGES" --build-arg RUST_TOOLCHAINS="$RUST_TOOLCHAINS" \
      --build-arg NODE_MAJORS="$NODE_MAJORS" --build-arg SCCACHE_VERSION="$SCCACHE_VERSION" \
      --build-arg COSIGN_VERSION="$COSIGN_VERSION" --build-arg COSIGN_SHA256="$COSIGN_SHA256" \
      --build-arg OTP_VERSION="$OTP_VERSION" --build-arg OTP_SHA256="$OTP_SHA256" \
      --build-arg ELIXIR_VERSION="$ELIXIR_VERSION" --build-arg ELIXIR_SHA256="$ELIXIR_SHA256" - <<'DOCKERFILE' 2>&1 \
      | grep --line-buffered -E '^#[0-9]+ (DONE|CACHED|\[)|Setting up|ERROR' | sed -u 's/^/    /' || true
ARG BASE
FROM ${BASE}
USER root
ARG PACKAGES
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${PACKAGES} && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /usr/local/lib/docker/cli-plugins && curl -fsSL https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.47.2/yq_linux_amd64 -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
# Rust: rustup with the toolchains the workflows ask for (+ clippy, rustfmt). The workflows repoint CARGO_HOME
# to the /cache volume; the toolchains stay here in RUSTUP_HOME.
ARG RUST_TOOLCHAINS
ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
ENV PATH=/opt/cargo/bin:${PATH}
RUN set -e; curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --no-modify-path --default-toolchain none; \
    for t in ${RUST_TOOLCHAINS}; do rustup toolchain install "$t" --profile minimal -c clippy -c rustfmt; done; \
    rustup default "${RUST_TOOLCHAINS%% *}"; rm -rf /opt/cargo/registry
ARG SCCACHE_VERSION
RUN curl -fsSL "https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}/sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl.tar.gz" | tar -xz -C /usr/local/bin --strip-components=1 "sccache-v${SCCACHE_VERSION}-x86_64-unknown-linux-musl/sccache"
# Node: latest of each major under /opt/node/<major>; pnpm comes through corepack (downloads cached in /cache).
ARG NODE_MAJORS
RUN set -e; for v in ${NODE_MAJORS}; do mkdir -p /opt/node/$v; \
    f=$(curl -fsSL https://nodejs.org/dist/latest-v$v.x/SHASUMS256.txt | grep 'linux-x64.tar.xz' | awk '{print $2}'); \
    curl -fsSL https://nodejs.org/dist/latest-v$v.x/$f | tar -xJ -C /opt/node/$v --strip-components=1; done
# Trivy and cosign (docker.yml detects them and skips the downloads).
RUN curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
ARG COSIGN_VERSION
ARG COSIGN_SHA256
RUN curl -fsSL -o /usr/local/bin/cosign https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64 && echo "${COSIGN_SHA256}  /usr/local/bin/cosign" | sha256sum -c - && chmod +x /usr/local/bin/cosign
# Erlang/OTP + Elixir under /opt/beam/otp-<v> and /opt/beam/elixir-<v>-otp-<major> (elixir.yml detects them).
ARG OTP_VERSION
ARG OTP_SHA256
ARG ELIXIR_VERSION
ARG ELIXIR_SHA256
RUN set -e; d=/opt/beam/otp-${OTP_VERSION}; mkdir -p $d /tmp/otp; \
    curl -fsSL -o /tmp/otp.tgz "https://builds.hex.pm/builds/otp/ubuntu-24.04/OTP-${OTP_VERSION}.tar.gz"; \
    echo "${OTP_SHA256}  /tmp/otp.tgz" | sha256sum -c -; tar -xzf /tmp/otp.tgz -C /tmp/otp --strip-components=1; \
    cp -a /tmp/otp/. $d/; (cd $d && ./Install -minimal "$d" >/dev/null); rm -rf /tmp/otp /tmp/otp.tgz; \
    e=/opt/beam/elixir-${ELIXIR_VERSION}-otp-${OTP_VERSION%%.*}; mkdir -p $e; \
    curl -fsSL -o /tmp/elixir.zip "https://builds.hex.pm/builds/elixir/v${ELIXIR_VERSION}-otp-${OTP_VERSION%%.*}.zip"; \
    echo "${ELIXIR_SHA256}  /tmp/elixir.zip" | sha256sum -c -; unzip -q /tmp/elixir.zip -d $e; rm /tmp/elixir.zip; \
    PATH=$d/bin:$e/bin:$PATH elixir --version | tail -1
RUN mkdir -p /cache
DOCKERFILE
    docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || { echo "building $LOCAL_IMAGE failed"; exit 1; }
    echo "Pre-pulling testcontainers images"
    for img in $PREPULL_IMAGES; do docker pull -q "$img" >/dev/null 2>&1 && echo "    $img" || echo "    $img: pull failed (skipped)"; done
    for i in $(seq 1 "$COUNT"); do
      c="$CONTAINER-$i"; n="$PREFIX-$i"
      echo "  [$i/$COUNT] starting container $c"
      token="$(gh api -X POST "orgs/$ORG/actions/runners/registration-token" -q .token)"
      # The work dir has the same path on the host and in the container: jobs talk to the host's Docker, so a
      # bind mount of $GITHUB_WORKSPACE (docker run -v "$GITHUB_WORKSPACE:/repo") must resolve on the host too.
      work="/srv/discordy-runner/$c/_work"
      docker run -d --restart unless-stopped --name "$c" --user root \
        -e RUNNER_ALLOW_RUNASROOT=1 -e REG_TOKEN="$token" -e ORG="$ORG" -e NAME="$n" -e LABEL="$LABEL" -e PACKAGES="$PACKAGES" -e WORK="$work" \
        -v /var/run/docker.sock:/var/run/docker.sock -v "$work:$work" -v "$CACHE_VOLUME:/cache" $NETWORK_ARGS \
        "$LOCAL_IMAGE" bash -c "$(cat "$(dirname "$0")/runner-entrypoint.sh")" >/dev/null
    done
    online=0; ready=0
    echo "Waiting for the runners to register with GitHub (follow one with: docker logs -f $CONTAINER-1)"
    last=-1
    for _ in $(seq 1 150); do
      online="$(runners_json | jq -s --arg prefix "$PREFIX" --argjson count "$COUNT" '[.[] | select(.status == "online") | .name as $name | select([range(1; $count + 1) | "\($prefix)-\(.)"] | index($name) != null)] | length')"
      [[ "$online" != "$last" ]] && { echo "  online: $online/$COUNT"; last="$online"; }
      ready=0
      for i in $(seq 1 "$COUNT"); do
        c="$CONTAINER-$i"
        if docker exec "$c" bash -c 'cd /home/runner && test -f .runner && test -f .credentials && test -f .credentials_rsaparams' >/dev/null 2>&1; then
          ready=$((ready + 1))
        fi
      done
      [[ "$online" -ge "$COUNT" && "$ready" -eq "$COUNT" ]] && break
      sleep 2
    done
    echo "runners online ($LABEL): $online/$COUNT"
    [[ "$online" -ge "$COUNT" && "$ready" -eq "$COUNT" ]] || { echo "not all requested runners registered; CI_RUNNER was not changed" >&2; exit 1; }
    if [[ -z "$HOST" ]]; then
      [[ "$online" -gt 0 ]] || { echo "no runner came online; CI_RUNNER was not changed" >&2; exit 1; }
      set_runner_var "$LABEL"
    fi
    [[ -n "$HOST" ]] && echo "send jobs here with: scripts/runner.sh use $LABEL"
    ;;
  down)
    current="$(get_runner_var)"
    others="$(runners_json | jq -s "[.[] | select(.status==\"online\") | select(any(.labels[]; .name==\"$LABEL\")) | select(.name|startswith(\"$PREFIX-\")|not)] | length")"
    if [[ "$current" == "$LABEL" ]]; then echo "CI_RUNNER stays on $LABEL; $others other runner(s) in the pool are online (jobs queue if none remain)"; fi
    for c in $(docker ps -a --format '{{.Names}}' | grep -E "^$CONTAINER(-[0-9]+)?$" || true); do
      token="$(gh api -X POST "orgs/$ORG/actions/runners/remove-token" -q .token)"
      echo "  removing $c"
      # A runner that never finished registering has nothing to remove; don't let that block down.
      timeout 30 docker exec -e T="$token" "$c" bash -c 'cd /home/runner && [ -f .runner ] && ./config.sh remove --token "$T"' >/dev/null 2>&1 || true
      docker rm -f "$c" >/dev/null
    done
    # Native Windows gh/jq can terminate piped records with CRLF; command substitution
    # may remove only LF and otherwise pass an invalid control character to gh.
    for id in $(runners_json | jq -r "select(.name|startswith(\"$PREFIX-\")) | .id" | tr -d '\r'); do
      gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null || true
    done
    echo "runners $LABEL removed"
    ;;
  use)
    [[ -n "${TARGET:-}" && "$TARGET" != github && "$TARGET" != ubuntu-* ]] || { echo "usage: $0 use <self-hosted-label>"; exit 2; }
    if [[ "$TARGET" != github ]]; then
      n="$(runners_json | jq -s "[.[] | select(.labels[].name==\"$TARGET\") | select(.status==\"online\")] | length")"
      [[ "$n" -gt 0 ]] || { echo "no online runner has label $TARGET; start it first (scripts/runner.sh up ...)"; exit 1; }
    fi
    set_runner_var "$TARGET"
    ;;
  status)
    v="$(get_runner_var)"; v="${v:-<unset: shared workflows use vm-runner>}"
    echo "CI_RUNNER (api): $v"
    echo "this machine: runners named $PREFIX-N, label $LABEL"
    docker ps --filter "name=^$CONTAINER" --format '{{.Names}}: {{.Status}}' 2>/dev/null || true
    docker run --rm -v "$CACHE_VOLUME:/cache" alpine du -sh /cache 2>/dev/null | sed "s|^|cache volume $CACHE_VOLUME: |" || true
    runners_json | jq -r 'select(.status=="online") | "\(.name) [\([.labels[].name]|join(","))] busy=\(.busy)"'
    ;;
  cache-clear)
    # Wipe the persistent CI cache (all of it, or --what a part). Refuses while a runner of this label is busy
    # (a job could be writing a target dir) unless --force.
    busy="$(runners_json | jq -s "[.[] | select(.name|startswith(\"$PREFIX-\")) | select(.busy==true)] | length")"
    if [[ "$busy" -gt 0 && "$FORCE" -ne 1 ]]; then echo "$busy runner(s) of $LABEL are busy; retry when idle (or --force)"; exit 1; fi
    case "$WHAT" in
      all) paths='/cache/* /cache/.[!.]* /srv/discordy-runner/*/_work/.pnpm-store' ;;
      cargo) paths='/cache/cargo' ;;
      target) paths='/cache/target' ;;
      sccache) paths='/cache/sccache' ;;
      # The pnpm store lives in each runner's work dir (same filesystem as the checkout, so installs hardlink).
      pnpm) paths='/cache/pnpm-store /cache/corepack /srv/discordy-runner/*/_work/.pnpm-store' ;;
      trivy) paths='/cache/trivy' ;;
      mix) paths='/cache/mix /cache/hex /cache/mixcache' ;;
      *) echo "--what must be all|cargo|target|sccache|pnpm|trivy|mix"; exit 2 ;;
    esac
    echo "Clearing $WHAT in volume $CACHE_VOLUME"
    docker run --rm -v "$CACHE_VOLUME:/cache" -v /srv/discordy-runner:/srv/discordy-runner alpine sh -c "rm -rf $paths; du -sh /cache"
    if [[ "$LAYERS" -eq 1 ]]; then echo "Pruning the Docker build (layer) cache"; docker builder prune -af | tail -1; fi
    ;;
  *) echo "usage: $0 up|down|use|status|cache-clear [--host user@vm] [--count N] [--label L] [--what X] [--layers] [--force]"; exit 2 ;;
esac
