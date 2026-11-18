#!/usr/bin/env bash
set -eu
printf 'docker %s\n' "$*" >> "$CALLS"
case "$1" in
  info) printf '%s %s\n' "$CPU_FIXTURE" "$MEMORY_FIXTURE" ;;
  ps) cat "$CONTAINERS_FILE" ;;
  *)
    [[ "$ALLOW_STARTUP" == 1 ]] || { echo "unexpected Docker mutation: $*" >&2; exit 97; }
    case "$1" in
      build)
        cat >/dev/null
        [[ -z "$AFTER_BUILD_CONTAINERS" ]] || printf '%s' "$AFTER_BUILD_CONTAINERS" >> "$CONTAINERS_FILE"
        printf '#1 DONE\n'
        ;;
      image|pull) ;;
      rm)
        [[ "$2" != -f ]] || exit 96
        awk -F '\t' -v name="$2" '$1 == name && $2 != "exited" && $2 != "dead" {exit 1}' "$CONTAINERS_FILE" || exit 95
        awk -F '\t' -v name="$2" '$1 != name' "$CONTAINERS_FILE" > "$CONTAINERS_FILE.next"
        mv "$CONTAINERS_FILE.next" "$CONTAINERS_FILE"
        ;;
      run)
        container='' runner=''
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --name) container="$2"; shift ;;
            NAME=*) runner="${1#NAME=}" ;;
          esac
          shift
        done
        if awk -F '\t' -v name="$container" '$1 == name {found=1} END {exit !found}' "$CONTAINERS_FILE"; then exit 94; fi
        printf '%s\trunning\n' "$container" >> "$CONTAINERS_FILE"
        printf '%s' "${runner%-*}" > "$PREFIX_FILE"
        printf 'fixture-container-id\n'
        ;;
      *) exit 93 ;;
    esac
    ;;
esac
