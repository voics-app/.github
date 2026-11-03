#!/usr/bin/env bash
# Release one repo with git-flow: develop -> release/<v> -> PR into main -> wait for its checks -> merge ->
# wait for main CI on the merge commit -> annotated tag v<v> -> back-merge main into develop.
#   scripts/release.sh <repo> <X.Y.Z>        (run from the folder that holds the repo checkouts, or set BASE)
# The tag is only created after main CI is green, so tag builds skip re-running the checks (shared
# workflows' "verified" job) and a red main is never tagged.
set -uo pipefail
r=$1; v=$2; base="${BASE:-$(pwd)}"
cd "$base/$r" && git fetch -q origin --tags || { echo "$r: fetch failed"; exit 1; }
git rev-parse -q --verify "refs/tags/v$v" >/dev/null && { echo "$r: tag v$v already exists"; exit 1; }
git push -q origin "origin/develop:refs/heads/release/$v" || { echo "$r: push release/$v failed"; exit 1; }
n=$(gh pr create -R "discordy-voics/$r" -B main -H "release/$v" -t "release: $r $v" -b "Release $v (develop -> main).

🤖 Generated with [Claude Code](https://claude.com/claude-code)" | grep -o '[0-9]*$') || { echo "$r: PR create failed"; exit 1; }
echo "$r: release PR #$n"
for i in $(seq 1 120); do
  o=$(gh pr view "$n" -R "discordy-voics/$r" --json statusCheckRollup -q '"\(.statusCheckRollup|length) \([.statusCheckRollup[]|select(.status!="COMPLETED")]|length) \([.statusCheckRollup[]|select(.conclusion=="FAILURE" or .conclusion=="CANCELLED" or .conclusion=="TIMED_OUT")|.name]|join(";"))"')
  set -- $o
  [ -n "${3:-}" ] && { echo "$r: PR #$n FAILING: $3"; exit 1; }
  [ "$1" -gt 0 ] && [ "$2" = 0 ] && break
  sleep 60
done
gh pr merge "$n" -R "discordy-voics/$r" --merge >/dev/null || { echo "$r: merge failed"; exit 1; }
git fetch -q origin
# Tag only after main's CI passed on this exact commit: never tag a red main, and the tag build then skips
# re-running the checks (shared workflows' "verified" job) and only builds/publishes the version image.
sha=$(git rev-parse origin/main)
for i in $(seq 1 120); do
  s=$(gh api "repos/discordy-voics/$r/actions/runs?head_sha=$sha&branch=main&event=push" -q '[.workflow_runs[]|select(.name=="ci")][0]|"\(.status) \(.conclusion)"' 2>/dev/null)
  case "$s" in "completed success") echo "$r: main CI green on ${sha:0:7}"; break;; completed*) echo "$r: main CI $s on ${sha:0:7}, not tagging"; exit 1;; esac
  sleep 60
done
W=$(mktemp -d); git worktree add -q --detach "$W" origin/main
( cd "$W" && git tag -a "v$v" origin/main -m "v$v" && git push -q origin "v$v" \
  && git checkout -q --detach origin/develop && git merge -q --no-edit origin/main && git push -q origin HEAD:develop ) \
  && echo "$r: v$v tagged + back-merged" || echo "$r: tag/back-merge failed"
git worktree remove --force "$W"; git push -q origin --delete "release/$v" 2>/dev/null; true
