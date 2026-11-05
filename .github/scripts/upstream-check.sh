#!/usr/bin/env bash
# Detection for .github/workflows/upstream-update.yml (job `check`). Runs locally too:
#
#   .github/scripts/upstream-check.sh [<target version>]   # needs curl, jq, gh (authenticated)
#   .github/scripts/upstream-check.sh next-version <our version> <upstream version>
#
# Prints key=value lines (also appended to $GITHUB_OUTPUT on CI): from, to, version, branch,
# update (true|false), reason.
set -euo pipefail

# Our version for an upstream release: a new upstream major.minor X.Y gives X.Y.0, an upstream
# patch of the minor we already mirror gives our next patch (the patch is ours, see PLAN.md).
next_version() {
  local ours=$1 upstream=$2
  local o_major o_minor o_patch u_major u_minor
  IFS=. read -r o_major o_minor o_patch <<<"$ours"
  IFS=. read -r u_major u_minor _ <<<"$upstream"
  if [[ $o_major == "$u_major" && $o_minor == "$u_minor" ]]; then
    echo "$o_major.$o_minor.$((o_patch + 1))"
  else
    echo "$u_major.$u_minor.0"
  fi
}

# True when $1 > $2 (both X.Y.Z).
newer() { [[ $1 != "$2" && $(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1) == "$1" ]]; }

if [[ ${1:-} == next-version ]]; then
  next_version "$2" "$3"
  exit 0
fi

root=$(cd "$(dirname "$0")/../.." && pwd)
repo=${GITHUB_REPOSITORY:-ftes/playwright_ex}
target=${1:-}
# A target given by hand is a deliberate retry: only an open PR blocks it, not a closed one.
if [[ -n $target ]]; then states=open; else states=all; fi
stable='^[0-9]+\.[0-9]+\.[0-9]+$'

out() {
  echo "$1=$2"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; fi
}

stop() {
  out update false
  out reason "$1"
  exit 0
}

from=$(sed -nE 's/^ *@driver_version "([^"]+)".*/\1/p' "$root/lib/playwright_ex/driver.ex")
ours=$(sed -nE 's/^ *@version "([^"]+)".*/\1/p' "$root/mix.exs")
[[ $from =~ $stable && $ours =~ $stable ]] || { echo "cannot read @driver_version/@version" >&2; exit 1; }
out from "$from"

# The driver is the playwright-core npm package (PlaywrightEx.Driver.npm_url/0), so the npm
# registry is the source of truth: dist-tags.latest is the stable release (next/beta are tagged
# otherwise).
meta=$(curl -fsSL --retry 3 https://registry.npmjs.org/playwright-core)
if [[ -z $target ]]; then
  target=$(jq -r '."dist-tags".latest' <<<"$meta")
fi
out to "$target"

[[ $target =~ $stable ]] || stop "$target is not a stable X.Y.Z version"
jq -e --arg v "$target" '.versions[$v]' <<<"$meta" >/dev/null || stop "playwright-core@$target is not on npm"
newer "$target" "$from" || stop "$target is not newer than the pinned $from"

# The port diffs the upstream tags; npm can publish before the GitHub tag exists.
gh api "repos/microsoft/playwright/git/ref/tags/v$target" --silent 2>/dev/null ||
  stop "microsoft/playwright has no tag v$target yet"

branch="upstream/$target"
out branch "$branch"
out version "$(next_version "$ours" "$target")"

# Dedup: the branch (a run in progress, or a PR's head) or a PR from it, open or closed, means
# the release is handled. To retry: close the PR, delete the branch, dispatch with the version.
prs=$(gh pr list --repo "$repo" --head "$branch" --state "$states" --json url --jq '[.[].url] | join(" ")')
[[ -z $prs ]] || stop "PR exists: $prs"
if err=$(gh api "repos/$repo/git/ref/heads/$branch" --silent 2>&1); then
  stop "branch $branch exists"
elif [[ $err != *"404"* ]]; then
  echo "branch lookup failed: $err" >&2
  exit 1
fi

out update true
out reason "playwright $target is newer than the pinned $from"
