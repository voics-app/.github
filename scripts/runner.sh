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
PACKAGES="libatomic1 build-essential pkg-config libssl-dev cmake clang unzip zstd jq python3 git curl ca-certificates xz-utils"
REPOS=(api messages gateway voice admin client website gitops docs contracts .github bots-sdk)

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
# Jobs start sibling containers on the host's Docker (testcontainers) and reach them on mapped ports:
# on a Linux VM the runner shares the host network, so "localhost" works; on Docker Desktop the
# containers are reached through host.docker.internal.
if [[ -n "$HOST" || "$(uname -s)" == Linux ]]; then
  NETWORK_ARGS="--network host"
else
  NETWORK_ARGS="--add-host host.docker.internal:host-gateway -e TESTCONTAINERS_HOST_OVERRIDE=host.docker.internal"
fi

runners_json() { gh api --paginate "orgs/$ORG/actions/runners?per_page=100" -q ".runners[]"; }
set_runner_var() {
  for r in "${REPOS[@]}"; do
    if [[ "$1" == github ]]; then gh variable delete CI_RUNNER -R "$ORG/$r" >/dev/null 2>&1 || true
    else gh variable set CI_RUNNER -R "$ORG/$r" --body "$1" >/dev/null; fi
  done
  echo "CI_RUNNER -> $1 in ${#REPOS[@]} repos"
}

case "$cmd" in
  up)
    echo "Starting $COUNT runner(s) with label $LABEL (first run downloads the image; each runner installs build packages, 2-5 min)"
    for i in $(seq 1 "$COUNT"); do
      c="$CONTAINER-$i"; n="$LABEL-$i"
      echo "  [$i/$COUNT] starting container $c"
      docker rm -f "$c" >/dev/null 2>&1 || true
      token="$(gh api -X POST "orgs/$ORG/actions/runners/registration-token" -q .token)"
      docker run -d --name "$c" --user root \
        -e RUNNER_ALLOW_RUNASROOT=1 -e REG_TOKEN="$token" -e ORG="$ORG" -e NAME="$n" -e LABEL="$LABEL" -e PACKAGES="$PACKAGES" \
        -v /var/run/docker.sock:/var/run/docker.sock $NETWORK_ARGS \
        "$IMAGE" bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq $PACKAGES >/dev/null && cd /home/runner && ./config.sh --unattended --replace --url "https://github.com/$ORG" --token "$REG_TOKEN" --name "$NAME" --labels "$LABEL" --no-default-labels && unset REG_TOKEN && exec ./run.sh' >/dev/null
    done
    online=0
    echo "Waiting for the runners to register with GitHub (follow one with: docker logs -f $CONTAINER-1)"
    last=-1
    for _ in $(seq 1 150); do
      online="$(runners_json | jq -s "[.[] | select(.name|startswith(\"$LABEL-\")) | select(.status==\"online\")] | length")"
      [[ "$online" != "$last" ]] && { echo "  online: $online/$COUNT"; last="$online"; }
      [[ "$online" -ge "$COUNT" ]] && break
      sleep 2
    done
    echo "runners online ($LABEL): $online/$COUNT"
    [[ -z "$HOST" ]] && set_runner_var "$LABEL"   # started on this machine (PC or VM): send jobs here
    [[ -n "$HOST" ]] && echo "send jobs here with: scripts/runner.sh use $LABEL"
    ;;
  down)
    current="$(gh variable get CI_RUNNER -R "$ORG/api" 2>/dev/null || true)"
    [[ "$current" == "$LABEL" ]] && set_runner_var github
    for c in $(docker ps -a --format '{{.Names}}' | grep -E "^$CONTAINER(-[0-9]+)?$" || true); do
      token="$(gh api -X POST "orgs/$ORG/actions/runners/remove-token" -q .token)"
      docker exec -e T="$token" "$c" bash -c 'cd /home/runner && ./config.sh remove --token "$T"' >/dev/null 2>&1 || true
      docker rm -f "$c" >/dev/null
    done
    for id in $(runners_json | jq -r "select(.name==\"$LABEL\" or (.name|startswith(\"$LABEL-\"))) | .id"); do
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
    echo "CI_RUNNER (api): $(gh variable get CI_RUNNER -R "$ORG/api" 2>/dev/null || echo '<unset: GitHub-hosted ubuntu-latest>')"
    docker ps --filter "name=^$CONTAINER" --format '{{.Names}}: {{.Status}}' 2>/dev/null || true
    runners_json | jq -r 'select(.status=="online") | "\(.name) [\([.labels[].name]|join(","))] busy=\(.busy)"'
    ;;
  *) echo "usage: $0 up|down|use|status [--host user@vm] [--count N] [--label L]"; exit 2 ;;
esac
