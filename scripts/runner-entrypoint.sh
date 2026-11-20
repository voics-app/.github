#!/usr/bin/env bash
# Embedded in each container command by runner.sh. Registration persists in the
# container writable layer across Docker restarts, not across container removal.
set -euo pipefail
cd "${RUNNER_HOME:-/home/runner}"
exec 9>.discordy-listener.lock
flock -n 9 || { echo "runner listener already active" >&2; exit 1; }
if [[ -f .runner && -f .credentials && -f .credentials_rsaparams ]]; then
  unset REG_TOKEN
elif [[ -e .runner || -e .credentials || -e .credentials_rsaparams ]]; then
  echo "incomplete runner registration; manual recovery required" >&2
  exit 1
else
  : "${REG_TOKEN:?missing registration token}"
  ./config.sh --unattended --url "https://github.com/$ORG" --token "$REG_TOKEN" --name "$NAME" --labels "$LABEL" --no-default-labels --work "$WORK"
  unset REG_TOKEN
  [[ -f .runner && -f .credentials && -f .credentials_rsaparams ]] || { echo "runner registration did not complete" >&2; exit 1; }
fi
exec ./run.sh
