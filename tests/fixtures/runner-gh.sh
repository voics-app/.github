#!/usr/bin/env bash
set -eu
printf 'gh %s\n' "$*" >> "$CALLS"
[[ "$ALLOW_STARTUP" == 1 ]] || exit 98
case "$*" in
  *registration-token*) printf 'fixture-token\n' ;;
  *'--paginate'*)
    prefix="$(cat "$PREFIX_FILE")"
    while IFS=$'\t' read -r container state; do
      [[ "$state" == running && "$container" == discordy-runner-vm-runner-* ]] || continue
      printf '{"name":"%s-%s","status":"online"}\n' "$prefix" "${container##*-}"
    done < "$CONTAINERS_FILE"
    ;;
  'variable set '*) ;;
  *) exit 92 ;;
esac
