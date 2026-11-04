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
# Resumable: reuse an open release PR (e.g. after a stopped run) instead of failing on "already exists".
n=$(gh pr list -R "discordy-voics/$r" -H "release/$v" -B main --state open --json number -q '.[0].number')
[ -n "$n" ] || n=$(gh pr create -R "discordy-voics/$r" -B main -H "release/$v" -t "release: $r $v" -b "Release $v (develop -> main).

🤖 Generated with [Claude Code](https://claude.com/claude-code)" | grep -o '[0-9]*$') || { echo "$r: PR create failed"; exit 1; }
echo "$r: release PR #$n"
for i in $(seq 1 120); do
  o=$(gh pr view "$n" -R "discordy-voics/$r" --json statusCheckRollup -q '"\(.statusCheckRollup|length) \([.statusCheckRollup[]|select(.status!="COMPLETED")]|length) \([.statusCheckRollup[]|select(.conclusion=="FAILURE" or .conclusion=="TIMED_OUT")|.name]|join(";"))"')
  set -- $o
  [ -n "${3:-}" ] && { echo "$r: PR #$n FAILING: $3"; exit 1; }
  # A cancelled run (superseded or cancelled by hand) is not a verdict: wait until that check has a green re-run.
  [ "$1" -gt 0 ] && [ "$2" = 0 ] && [ -z "$(gh pr view "$n" -R "discordy-voics/$r" --json statusCheckRollup -q '[.statusCheckRollup[]] as $c | [$c[]|select(.conclusion=="CANCELLED")|.name|select(. as $n|[$c[]|select(.name==$n and (.conclusion=="SUCCESS" or .conclusion=="SKIPPED"))]|length==0)]|.[0] // empty')" ] && { pr_green=1; break; }
  sleep 60
done
[ "${pr_green:-0}" = 1 ] || { echo "$r: PR #$n not green within the wait, not merging"; exit 1; }
gh pr merge "$n" -R "discordy-voics/$r" --merge >/dev/null || { echo "$r: merge failed"; exit 1; }
git fetch -q origin
# Tag only after main's CI passed on this exact commit: never tag a red main, and the tag build then skips
# re-running the checks (shared workflows' "verified" job) and only builds/publishes the version image.
# The merge commit from GitHub, not origin/main: a fetch right after the merge can still see the old main,
# and waiting on that SHA never finds a main run (website 0.3.1 stalled on this).
sha=$(gh pr view "$n" -R "discordy-voics/$r" --json mergeCommit -q .mergeCommit.oid)
for _ in $(seq 1 10); do git fetch -q origin; [ "$(git rev-parse origin/main)" = "$sha" ] && break; sleep 6; done
# Every push workflow on the merge commit must pass, whatever it is called (api/client "ci", docs "docs", ...).
ALL_GREEN='[.workflow_runs[]] as $w | if ($w|length)==0 then "" elif any($w[]; .status!="completed") then "running"
  elif all($w[]; .conclusion=="success" or .conclusion=="skipped") then "completed success" else "completed failure" end'
for i in $(seq 1 120); do
  s=$(gh api "repos/discordy-voics/$r/actions/runs?head_sha=$sha&branch=main&event=push" -q "$ALL_GREEN" 2>/dev/null)
  case "$s" in "completed success") echo "$r: main CI green on ${sha:0:7}"; break;; completed*) echo "$r: main CI $s on ${sha:0:7}, not tagging"; exit 1;; esac
  sleep 60
done
# No green main run within the wait (or the repo has no CI on main): never tag unverified.
[[ "$s" == "completed success" ]] || { echo "$r: no green main CI run for ${sha:0:7} (last: '${s:-none}'), not tagging"; exit 1; }
W=$(mktemp -d); git worktree add -q --detach "$W" origin/main
# client's release workflow tags the version itself (client#195): reuse that tag when it is on this commit.
tag_v() {
  if git ls-remote --exit-code -q origin "refs/tags/v$v" >/dev/null; then
    git fetch -q origin "+refs/tags/v$v:refs/tags/v$v" && [ "$(git rev-parse "v$v^{commit}")" = "$sha" ] \
      && echo "$r: v$v already tagged by CI"
  else
    git tag -a "v$v" origin/main -m "v$v" && git push -q origin "v$v"
  fi
}
( cd "$W" && tag_v \
  && git checkout -q --detach origin/develop && git merge -q --no-edit origin/main && git push -q origin HEAD:develop ) \
  && echo "$r: v$v tagged + back-merged" || echo "$r: tag/back-merge failed"
git worktree remove --force "$W"; git push -q origin --delete "release/$v" 2>/dev/null; true
