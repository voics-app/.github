#!/usr/bin/env bash
# On-demand self-hosted GitHub Actions runner on the owner's PC (temporary relief when the GitHub-hosted
# minutes quota runs low). GitHub-hosted runners stay the default:
#
#   scripts/pc-runner.sh up       start the runner container (label karma-pc) and set CI_RUNNER=karma-pc
#                                 in every repo, so the shared workflows' default runner becomes this PC
#   scripts/pc-runner.sh down     unset CI_RUNNER everywhere (back to ubuntu-latest), deregister, remove
#   scripts/pc-runner.sh status
#
# Needs Docker Desktop and `gh` with admin:org (registration tokens) - set GH_TOKEN to a PAT if the gh
# login lacks it. The container has no restart policy: after a reboot the runner is off and jobs queue
# on GitHub-hosted runners only if CI_RUNNER was cleared, so run `down` before shutting the PC off.
set -euo pipefail
export MSYS_NO_PATHCONV=1
ORG=discordy-voics
NAME="${PC_RUNNER_NAME:-karma-pc}"
LABEL="${PC_RUNNER_LABEL:-karma-pc}"
IMAGE=ghcr.io/actions/actions-runner:2.338.0   # same runner version as the in-cluster ARC scale set
CONTAINER=discordy-pc-runner
# The runner image is minimal; ubuntu-latest ships these (pnpm needs libatomic1, Rust/native builds the rest).
PACKAGES="libatomic1 build-essential pkg-config libssl-dev cmake clang unzip zstd jq python3 git curl ca-certificates xz-utils"
REPOS=(api messages gateway voice admin client website gitops docs contracts .github bots-sdk)

set_var() { for r in "${REPOS[@]}"; do gh variable set CI_RUNNER -R "$ORG/$r" --body "$LABEL" >/dev/null && echo "  CI_RUNNER=$LABEL on $r"; done; }
unset_var() { for r in "${REPOS[@]}"; do gh variable delete CI_RUNNER -R "$ORG/$r" >/dev/null 2>&1 && echo "  CI_RUNNER removed on $r" || true; done; }

case "${1:-status}" in
  up)
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    token="$(gh api -X POST "orgs/$ORG/actions/runners/registration-token" -q .token)"
    docker run -d --name "$CONTAINER" --user root \
      -e RUNNER_ALLOW_RUNASROOT=1 -e REG_TOKEN="$token" -e ORG="$ORG" -e NAME="$NAME" -e LABEL="$LABEL" -e PACKAGES="$PACKAGES" \
      -v /var/run/docker.sock:/var/run/docker.sock \
      "$IMAGE" bash -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq $PACKAGES >/dev/null && cd /home/runner && ./config.sh --unattended --replace --url "https://github.com/$ORG" --token "$REG_TOKEN" --name "$NAME" --labels "$LABEL" --no-default-labels && unset REG_TOKEN && exec ./run.sh' >/dev/null
    for _ in $(seq 1 90); do
      [[ "$(gh api --paginate "orgs/$ORG/actions/runners?per_page=100" -q ".runners[] | select(.name==\"$NAME\") | .status")" == online ]] && break
      sleep 2
    done
    echo "runner $NAME: $(gh api --paginate "orgs/$ORG/actions/runners?per_page=100" -q ".runners[] | select(.name==\"$NAME\") | .status")"
    set_var
    ;;
  down)
    unset_var
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
      token="$(gh api -X POST "orgs/$ORG/actions/runners/remove-token" -q .token)"
      docker exec -e T="$token" "$CONTAINER" bash -c 'cd /home/runner && ./config.sh remove --token "$T"' >/dev/null 2>&1 || true
      docker rm -f "$CONTAINER" >/dev/null
    fi
    id="$(gh api --paginate "orgs/$ORG/actions/runners?per_page=100" -q ".runners[] | select(.name==\"$NAME\") | .id")"
    [[ -n "$id" ]] && gh api -X DELETE "orgs/$ORG/actions/runners/$id" >/dev/null || true
    echo "runner $NAME removed; workflows use GitHub-hosted runners"
    ;;
  status)
    echo "container: $(docker ps --filter "name=^${CONTAINER}$" --format '{{.Status}}' || true)"
    echo "github:    $(gh api --paginate "orgs/$ORG/actions/runners?per_page=100" -q ".runners[] | select(.name==\"$NAME\") | .status + \" busy=\" + (.busy|tostring)" 2>/dev/null || echo unknown)"
    for r in "${REPOS[@]}"; do v="$(gh variable get CI_RUNNER -R "$ORG/$r" 2>/dev/null || true)"; echo "  $r: CI_RUNNER=${v:-<unset: ubuntu-latest>}"; done
    ;;
  *) echo "usage: $0 up|down|status"; exit 2 ;;
esac
