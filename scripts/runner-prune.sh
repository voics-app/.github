#!/usr/bin/env bash
# Keeps the self-hosted runner disk bounded. Runs daily from the `runner-maintenance` workflow (on a runner, through
# the host's Docker socket) and can be run by hand on the runner VM:
#
#   cd ~/.github && git pull && scripts/runner-prune.sh            # prune
#   scripts/runner-prune.sh --dry-run                              # only show what it would do
#   scripts/runner-prune.sh --deep                                 # also wipe the persistent Rust targets and sccache
#
# What it removes (everything it removes is rebuilt or re-downloaded on demand; see docs handbook 12):
#   - Docker build cache beyond BUILD_CACHE_MAX (default 15GB) and records unused for 14 days
#   - our own built images (ghcr.io/voics-app/*) older than 24 h that no container uses, and dangling images
#   - stopped containers older than 24 h (testcontainers leftovers) and unused anonymous volumes
#   - a pnpm store (per runner work dir) larger than PNPM_STORE_MAX_GB (default 3); it refills on the next install
#   - the old /cache/pnpm-store (unused since the store moved to the work dir)
# It never touches named volumes (the CI cache volume), the runner image or the pre-pulled testcontainers images.
# Exit code 3 when free disk stays under MIN_FREE_GB (default 20) after pruning, so the scheduled run turns red.
set -euo pipefail

DRY=0; DEEP=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --deep) DEEP=1 ;;
    *) echo "usage: $0 [--dry-run] [--deep]"; exit 2 ;;
  esac
done
BUILD_CACHE_MAX="${BUILD_CACHE_MAX:-15GB}"
PNPM_STORE_MAX_GB="${PNPM_STORE_MAX_GB:-3}"
MIN_FREE_GB="${MIN_FREE_GB:-20}"
WORK_ROOT="${WORK_ROOT:-/srv/discordy-runner}"
VOLUME="${CACHE_VOLUME:-$(docker volume ls -q --filter name=discordy-ci-cache- | head -1)}"

run() { if [[ "$DRY" -eq 1 ]]; then echo "  would run: $*"; else "$@"; fi; }
# File operations go through a throwaway container, so the script works the same on the VM host and inside a runner
# container (the volume and the work dirs are host paths either way).
fs() { docker run --rm ${VOLUME:+-v "$VOLUME:/cache"} -v "$WORK_ROOT:$WORK_ROOT" alpine:3.22 sh -c "$1"; }
DF_PATH="$WORK_ROOT"; [[ -n "$VOLUME" ]] && DF_PATH=/cache
free_gb() { fs "df -Pk $DF_PATH | awk 'NR==2 {print int(\$4/1048576)}'"; }

echo "== before: $(free_gb) GB free"
docker system df

echo "== Docker build cache: keep at most $BUILD_CACHE_MAX, drop records unused for 14 days"
run docker builder prune -f --filter until=336h
run docker builder prune -f --max-used-space "$BUILD_CACHE_MAX"

echo "== our images older than 24 h (in-use ones are skipped), dangling images"
cutoff=$(( $(date +%s) - 86400 ))
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.CreatedAt}}' | awk '$1 ~ /^ghcr\.io\/voics-app\//' |
  while read -r ref id created_date created_time _; do
    ts=$(date -d "$created_date $created_time" +%s 2>/dev/null || echo "$(date +%s)")
    if (( ts < cutoff )); then
      if [[ "$DRY" -eq 1 ]]; then echo "  would remove $ref"; else docker rmi "$ref" >/dev/null 2>&1 && echo "  removed $ref" || echo "  kept $ref (in use)"; fi
    fi
  done
run docker image prune -f

echo "== stopped containers older than 24 h, unused anonymous volumes"
run docker container prune -f --filter until=24h
run docker volume prune -f

echo "== pnpm stores over ${PNPM_STORE_MAX_GB} GB, the old /cache/pnpm-store"
script="for s in $WORK_ROOT/*/_work/.pnpm-store; do [ -d \"\$s\" ] || continue; g=\$(du -sk \"\$s\" | awk '{print int(\$1/1048576)}'); echo \"  \$s: \$g GB\"; if [ \"\$g\" -ge $PNPM_STORE_MAX_GB ]; then echo \"  -> wiping \$s\"; [ $DRY -eq 1 ] || rm -rf \"\$s\"; fi; done"
[[ -n "$VOLUME" ]] && script="$script; if [ -d /cache/pnpm-store ]; then echo '  -> removing /cache/pnpm-store'; [ $DRY -eq 1 ] || rm -rf /cache/pnpm-store; fi"
fs "$script"

if [[ "$DEEP" -eq 1 && -n "$VOLUME" ]]; then
  echo "== deep: persistent Rust targets and sccache (the next PR run of each repo compiles cold)"
  fs "du -sh /cache/target /cache/sccache 2>/dev/null; [ $DRY -eq 1 ] || rm -rf /cache/target /cache/sccache"
fi

left=$(free_gb)
echo "== after: $left GB free"
docker system df
if (( left < MIN_FREE_GB )); then
  echo "::error::runner disk still under $MIN_FREE_GB GB free ($left GB). Run with --deep, or grow the disk (docs handbook 12, 'Disk full')."
  exit 3
fi
