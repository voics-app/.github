#!/usr/bin/env bash
# Makes every voics-app repository public or private in one go, except gitops (always private: it holds
# the home IP and the whole infrastructure map). Also sets the CI runner to match:
#
#   public  -> delete the repo variable CI_RUNNER, so CI runs on GitHub-hosted runners (free for public
#              repositories). The runner group "Default" refuses public repositories, so our own VM and
#              in-cluster runners never take their jobs.
#   private -> set CI_RUNNER=vm-runner, so CI runs on the self-hosted VM pool (GitHub-hosted minutes for
#              private repositories are limited and billed).
#
#   scripts/repo-visibility.sh status                     show visibility and CI_RUNNER of every repo
#   scripts/repo-visibility.sh public  [--dry-run] [--yes] [repo ...]
#   scripts/repo-visibility.sh private [--dry-run] [--yes] [repo ...]
#
# Without repo names it acts on every repository except gitops. It asks for confirmation unless --yes.
# Needs: gh logged in as an org owner.
#
# Before making repositories public: run a secret scan of their full history first (see handbook
# 12-ci-runners-and-caching.md, "Public repositories and publishing"). Making a repo public cannot be undone
# in practice: anyone may have cloned it in the meantime.
# After making them private: gitops publish-public can no longer download their artifacts with its workflow
# token, so website/client publishing needs the minio-publish job back (or a token for publish-public).
set -euo pipefail
export MSYS_NO_PATHCONV=1
ORG=voics-app
KEEP_PRIVATE="gitops"
POOL_LABEL="${POOL_LABEL:-vm-runner}"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
cmd="${1:-}"; shift || true
[[ "$cmd" =~ ^(status|public|private)$ ]] || usage 1

dry=false yes=false repos=()
for a in "$@"; do
  case "$a" in
    --dry-run) dry=true ;;
    --yes) yes=true ;;
    -h|--help) usage ;;
    -*) echo "unknown option $a" >&2; exit 1 ;;
    *) repos+=("$a") ;;
  esac
done
if [[ ${#repos[@]} -eq 0 ]]; then
  mapfile -t repos < <(gh repo list "$ORG" --limit 200 --json name,isArchived --jq '.[] | select(.isArchived | not) | .name' | sort)
fi

ci_runner() { gh variable get CI_RUNNER -R "$ORG/$1" 2>/dev/null || echo "<unset: GitHub-hosted>"; }

if [[ "$cmd" == status ]]; then
  printf '%-12s %-9s %s\n' REPO VISIBILITY CI_RUNNER
  for r in "${repos[@]}"; do
    printf '%-12s %-9s %s\n' "$r" "$(gh repo view "$ORG/$r" --json visibility --jq .visibility)" "$(ci_runner "$r")"
  done
  exit 0
fi

targets=()
for r in "${repos[@]}"; do
  if [[ " $KEEP_PRIVATE " == *" $r "* ]]; then echo "skip $r (always private)"; continue; fi
  targets+=("$r")
done
[[ ${#targets[@]} -gt 0 ]] || { echo "nothing to do"; exit 0; }

echo "Make ${cmd}: ${targets[*]}"
if [[ "$dry" != true && "$yes" != true ]]; then
  read -r -p "Type '${cmd}' to continue: " answer
  [[ "$answer" == "$cmd" ]] || { echo "aborted"; exit 1; }
fi

if [[ "$cmd" == public ]]; then
  # Outside contributors' workflows always need an approval first; the runner group stays closed to public repos.
  if [[ "$dry" == true ]]; then
    echo "would: require approval for workflows of all outside contributors"
  else
    gh api -X PUT "orgs/$ORG/actions/permissions/fork-pr-contributor-approval" -f approval_policy=all_external_contributors >/dev/null
  fi
  open="$(gh api "orgs/$ORG/actions/runner-groups" --jq '[.runner_groups[] | select(.allows_public_repositories)] | length')"
  [[ "$open" == 0 ]] || echo "WARNING: a runner group allows public repositories; self-hosted runners could take public jobs" >&2
fi

for r in "${targets[@]}"; do
  if [[ "$dry" == true ]]; then
    echo "would: $r -> $cmd, CI_RUNNER $( [[ $cmd == public ]] && echo 'deleted' || echo "=$POOL_LABEL")"
    continue
  fi
  gh repo edit "$ORG/$r" --visibility "$cmd" --accept-visibility-change-consequences >/dev/null
  if [[ "$cmd" == public ]]; then
    gh variable delete CI_RUNNER -R "$ORG/$r" >/dev/null 2>&1 || true
  else
    gh variable set CI_RUNNER -R "$ORG/$r" --body "$POOL_LABEL" >/dev/null
    # A private .github must share its reusable workflows with the other (private) repositories.
    if [[ "$r" == .github ]]; then
      gh api -X PUT "repos/$ORG/.github/actions/permissions/access" -f access_level=organization >/dev/null
    fi
  fi
  echo "$r: $cmd, CI_RUNNER $(ci_runner "$r")"
done
