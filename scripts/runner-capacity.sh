#!/usr/bin/env bash
# Read-only admission plan for a dedicated CI Docker host. No registration tokens or mutations.
# Budget includes testcontainers/build work: 2 CPUs + 6 GiB per job, with 1 GiB left for the host.
runner_capacity_plan() {
  local label="$1" requested="$2" recreate="$3" resources cpus memory extra capacity memory_capacity inventory
  resources="$(docker info --format '{{.NCPU}} {{.MemTotal}}')" || return 1
  read -r cpus memory extra <<< "$resources"
  if [[ ! "$cpus" =~ ^[1-9][0-9]{0,5}$ || ! "$memory" =~ ^[1-9][0-9]{0,17}$ || -n "$extra" ]]; then
    echo 'Cannot determine Docker CPU/RAM capacity; refusing to start runners.' >&2
    return 1
  fi
  capacity=$((cpus / 2))
  memory_capacity=$(((memory - 1073741824) / 6442450944))
  (( memory_capacity < capacity )) && capacity=$memory_capacity
  if (( capacity < 1 )); then
    echo 'Docker capacity is below one runner (2 CPUs and 7 GiB including host reserve).' >&2
    return 1
  fi
  inventory="$(docker ps -a --format $'{{.Names}}\t{{.State}}')" || return 1
  printf '%s\n' "$inventory" | jq -Rsc \
    --arg prefix "discordy-runner-$label" --arg requested "$requested" \
    --argjson recreate "$recreate" --argjson capacity "$capacity" \
    --argjson cpus "$cpus" --argjson memory "$memory" '
    [split("\n")[] | rtrimstr("\r") | select(length > 0) | split("\t") |
      if length != 2 then error("Malformed Docker inventory; refusing to start runners") else
        {name: .[0], state: .[1]}
      end | select(.name | startswith("discordy-runner-")) |
      .state as $state |
      if (["created", "running", "paused", "restarting", "removing", "exited", "dead"] | index($state))
      then . else error("Unknown runner state; refusing to start runners") end
    ] as $all |
    def ours: .name == $prefix or
      (.name | startswith($prefix + "-") and (ltrimstr($prefix + "-") | test("^[0-9]+$")));
    def active: .state != "exited" and .state != "dead";
    [$all[] | select(active)] as $active |
    [$active[] | select(ours) | .name] | sort as $keep |
    ($active | length) as $host_active |
    ($host_active - ($keep | length)) as $other |
    (if $requested == "auto" then
       [($keep | length), ([3, ($capacity - $other)] | min)] | max
     else $requested | tonumber end) as $desired |
    if $host_active > $capacity then
      error("Existing runners exceed host capacity; drain excess runners manually before up")
    elif $desired < ($keep | length) then
      error("Existing runners exceed requested count; drain them manually (up never shrinks)")
    elif $desired < 1 or $desired + $other > $capacity then
      error("Requested runners exceed remaining host capacity, including other labels")
    elif $recreate == 1 and ($keep | length) > 0 then
      error("Drain and stop running runners manually before --recreate; no running container is removed")
    else
      ($desired - ($keep | length)) as $needed |
      (if $recreate > 0 then [$all[] | select(ours and (active | not)) | .name] | sort | .[:$needed]
       else [] end) as $replace |
      [$all[].name] as $names |
      [range(1; $desired + ($all | length) + 2) | $prefix + "-" + tostring |
        select(. as $name | $names | index($name) | not)] as $unused |
      {cpus: $cpus, memory_bytes: $memory, capacity: $capacity, desired: $desired,
       host_active: $host_active, other_active: $other, keep: $keep,
       start: ($replace + $unused[:($needed - ($replace | length))]), recreate: $replace}
    end'
}
