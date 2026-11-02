#!/usr/bin/env bash
# Self-hosted GitHub Actions runners for discordy-voics, on the owner's PC or on any Linux VM with Docker.
# GitHub-hosted ubuntu-latest stays the default; self-hosted runners are opt-in per repo variable CI_RUNNER,
# which the shared workflows' default runs-on follows (see README "CI runners").
#
#   scripts/runner.sh up     [--host user@vm] [--count N] [--label L]   start N runner containers (default 3)
#   scripts/runner.sh down   [--host user@vm] [--label L]               deregister and remove them
#   scripts/runner.sh use    github | <label>                           switch every repo's CI_RUNNER
#   scripts/runner.sh status [--host user@vm] [--label L]
#
# Every runner container mounts the persistent volume discordy-ci-cache-<label> at /cache (cargo registry and
# git, sccache, pnpm store, hex/mix), so dependency caches survive container recreation. Each runner's work
# dir is /srv/discordy-runner/<container>/_work at the same path on the host, so workflows can bind-mount
# $GITHUB_WORKSPACE into containers they start on the host's Docker.
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
IMAGE=ghcr.io/actions/actions-runner:2.338.0   # same runner version as the in-cluster ARC scale set
# The runner image is minimal; ubuntu-latest ships these (pnpm needs libatomic1, Rust/native builds the rest).
PACKAGES="gettext-base libatomic1 build-essential pkg-config libssl-dev cmake clang unzip zstd jq python3 python3-yaml git curl ca-certificates xz-utils"
REPOS=(api messages gateway voice admin client website gitops docs contracts .github bots-sdk)
# Repos whose CI runs on self-hosted runners when they are up (heavy Rust/Docker builds; free). The rest
# stay on GitHub-hosted runners (cheap, light jobs; $15/month budget). Override with SELF_HOSTED_REPOS="...".
read -ra SELF_HOSTED <<< "${SELF_HOSTED_REPOS:-api messages gateway voice client}"

cmd="${1:-status}"; shift || true
HOST=""; COUNT=3; LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --count) COUNT="$2"; shift 2 ;;
    --label) LABEL="$2"; shift 2 ;;
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
# Runner NAMES must be unique across machines (registration uses --replace, and down removes by name),
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
  local targets=("${REPOS[@]}")
  [[ "$1" != github ]] && targets=("${SELF_HOSTED[@]}")
  for r in "${targets[@]}"; do
    if [[ "$1" == github ]]; then gh variable delete CI_RUNNER -R "$ORG/$r" >/dev/null 2>&1 || true
    else gh variable set CI_RUNNER -R "$ORG/$r" --body "$1" >/dev/null; fi
  done
  echo "CI_RUNNER -> $1 in ${#targets[@]} repos (${targets[*]})"
}

case "$cmd" in
  up)
    echo "Starting $COUNT runner(s) with label $LABEL (first run downloads the image; each runner installs build packages, 2-5 min)"
    # Build packages into a local image once (cached afterwards), instead of apt-get in every container.
    LOCAL_IMAGE="discordy-actions-runner:${IMAGE##*:}"
    echo "Building $LOCAL_IMAGE (first time takes a few minutes; cached afterwards)"
    printf 'FROM %s
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends %s && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /usr/local/lib/docker/cli-plugins && curl -fsSL https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64 -o /usr/local/lib/docker/cli-plugins/docker-compose && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
RUN curl -fsSL https://github.com/mikefarah/yq/releases/download/v4.47.2/yq_linux_amd64 -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq
' "$IMAGE" "$PACKAGES"       | docker build --progress=plain -t "$LOCAL_IMAGE" - 2>&1 | grep --line-buffered -E '^#[0-9]+ (DONE|CACHED|\[)|Setting up|ERROR' | sed -u 's/^/    /' || true
    docker image inspect "$LOCAL_IMAGE" >/dev/null 2>&1 || { echo "building $LOCAL_IMAGE failed"; exit 1; }
    for i in $(seq 1 "$COUNT"); do
      c="$CONTAINER-$i"; n="$PREFIX-$i"
      echo "  [$i/$COUNT] starting container $c"
      docker rm -f "$c" >/dev/null 2>&1 || true
      token="$(gh api -X POST "orgs/$ORG/actions/runners/registration-token" -q .token)"
      # The work dir has the same path on the host and in the container: jobs talk to the host's Docker, so a
      # bind mount of $GITHUB_WORKSPACE (docker run -v "$GITHUB_WORKSPACE:/repo") must resolve on the host too.
      work="/srv/discordy-runner/$c/_work"
      docker run -d --name "$c" --user root \
        -e RUNNER_ALLOW_RUNASROOT=1 -e REG_TOKEN="$token" -e ORG="$ORG" -e NAME="$n" -e LABEL="$LABEL" -e PACKAGES="$PACKAGES" -e WORK="$work" \
        -v /var/run/docker.sock:/var/run/docker.sock -v "$work:$work" $NETWORK_ARGS \
        "$LOCAL_IMAGE" bash -c 'cd /home/runner && ./config.sh --unattended --replace --url "https://github.com/$ORG" --token "$REG_TOKEN" --name "$NAME" --labels "$LABEL" --no-default-labels --work "$WORK" && unset REG_TOKEN && exec ./run.sh' >/dev/null
    done
    online=0
    echo "Waiting for the runners to register with GitHub (follow one with: docker logs -f $CONTAINER-1)"
    last=-1
    for _ in $(seq 1 150); do
      online="$(runners_json | jq -s "[.[] | select(.name|startswith(\"$PREFIX-\")) | select(.status==\"online\")] | length")"
      [[ "$online" != "$last" ]] && { echo "  online: $online/$COUNT"; last="$online"; }
      [[ "$online" -ge "$COUNT" ]] && break
      sleep 2
    done
    echo "runners online ($LABEL): $online/$COUNT"
    [[ -z "$HOST" ]] && set_runner_var "$LABEL"   # started on this machine (PC or VM): send jobs here
    [[ -n "$HOST" ]] && echo "send jobs here with: scripts/runner.sh use $LABEL"
    ;;
  down)
    current="$(get_runner_var)"
    others="$(runners_json | jq -s "[.[] | select(.status==\"online\") | select(any(.labels[]; .name==\"$LABEL\")) | select(.name|startswith(\"$PREFIX-\")|not)] | length")"
    if [[ "$current" == "$LABEL" && "$others" -eq 0 ]]; then set_runner_var github
    elif [[ "$current" == "$LABEL" ]]; then echo "$others other runner(s) with label $LABEL still online: CI stays on $LABEL"; fi
    for c in $(docker ps -a --format '{{.Names}}' | grep -E "^$CONTAINER(-[0-9]+)?$" || true); do
      token="$(gh api -X POST "orgs/$ORG/actions/runners/remove-token" -q .token)"
      echo "  removing $c"
      # A runner that never finished registering has nothing to remove; don't let that block down.
      timeout 30 docker exec -e T="$token" "$c" bash -c 'cd /home/runner && [ -f .runner ] && ./config.sh remove --token "$T"' >/dev/null 2>&1 || true
      docker rm -f "$c" >/dev/null
    done
    for id in $(runners_json | jq -r "select(.name|startswith(\"$PREFIX-\")) | .id"); do
      gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null || true
    done
    echo "runners $LABEL removed"
    ;;
  use)
    [[ -n "${TARGET:-}" ]] || { echo "usage: $0 use github|<label>"; exit 2; }
    if [[ "$TARGET" != github ]]; then
      n="$(runners_json | jq -s "[.[] | select(.labels[].name==\"$TARGET\") | select(.status==\"online\")] | length")"
      [[ "$n" -gt 0 ]] || { echo "no online runner has label $TARGET; start it first (scripts/runner.sh up ...)"; exit 1; }
    fi
    set_runner_var "$TARGET"
    ;;
  status)
    v="$(get_runner_var)"; v="${v:-<unset: GitHub-hosted ubuntu-latest>}"
    echo "CI_RUNNER (api): $v"
    echo "this machine: runners named $PREFIX-N, label $LABEL"
    docker ps --filter "name=^$CONTAINER" --format '{{.Names}}: {{.Status}}' 2>/dev/null || true
    docker run --rm -v "$CACHE_VOLUME:/cache" alpine du -sh /cache 2>/dev/null | sed "s|^|cache volume $CACHE_VOLUME: |" || true
    runners_json | jq -r 'select(.status=="online") | "\(.name) [\([.labels[].name]|join(","))] busy=\(.busy)"'
    ;;
  *) echo "usage: $0 up|down|use|status [--host user@vm] [--count N] [--label L]"; exit 2 ;;
esac
