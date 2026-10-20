#!/usr/bin/env bash
# Kept for muscle memory: the PC runners are now managed by scripts/runner.sh (PC and VMs).
#   pc-runner.sh up|down|status  ==  runner.sh up|down|status   (label karma-pc, this machine)
exec "$(dirname "$0")/runner.sh" "${1:-status}" "${@:2}"
