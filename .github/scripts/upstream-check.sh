#!/usr/bin/env bash
# Read-only discovery for upstream-update.yml. Local use requires curl, jq, git and gh.
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
repo=${GITHUB_REPOSITORY:-ftes/playwright_ex}
requested=${1:-}
stable='^[0-9]+\.[0-9]+\.[0-9]+$'

report() {
  printf '%s\n' "$1"
  if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

from=$(<"$root/DRIVER_VERSION")
[[ $from =~ $stable && ( -z $requested || $requested =~ $stable ) ]] ||
  { echo "Expected stable X.Y.Z driver and target versions" >&2; exit 1; }

# The driver comes from npm. Its `latest` dist-tag excludes beta and next releases.
meta=$(curl -fsSL --retry 3 "https://registry.npmjs.org/playwright-core/${requested:-latest}")
to=$(jq -er '.version' <<< "$meta")
[[ $to =~ $stable && ( -z $requested || $to == "$requested" ) ]] ||
  { echo "Expected stable Playwright npm metadata" >&2; exit 1; }
if [[ $to == "$from" || $(printf '%s\n%s\n' "$from" "$to" | sort -V | tail -n1) != "$to" ]]; then
  report "Playwright $to is not newer than the pinned $from."
  exit 0
fi

# npm can publish first. For an annotated tag report the peeled commit.
ref="refs/tags/v$to"
if refs=$(git ls-remote --exit-code https://github.com/microsoft/playwright.git "$ref" "$ref^{}"); then
  sha=$(awk -v ref="$ref" '$2 == ref {tag=$1} $2 == ref "^{}" {peeled=$1}
    END {print (peeled ? peeled : tag)}' <<< "$refs")
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || { echo "Invalid upstream tag revision" >&2; exit 1; }
else
  status=$?
  if [[ $status != 2 ]]; then exit "$status"; fi
  report "Playwright $to is on npm; upstream tag v$to is not available yet."
  exit 0
fi

tracked=$(gh pr list --repo "$repo" --head "upstream/$to" --state all \
  --json state,isCrossRepository,url \
  --jq 'map(select(.state != "CLOSED" and (.isCrossRepository | not))) | first | .url // ""')
if [[ -n $tracked ]]; then
  report "Playwright $to already has a port PR: $tracked"
  exit 0
fi

# A retained notice deduplicates across runs even before a maintainer opens a PR.
name="upstream-release-$to"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  prior=$(gh api --method GET "repos/$repo/actions/artifacts" -f name="$name" \
    --jq '[.artifacts[] | select(.expired | not)] | first | .workflow_run.id // ""')
  if [[ -n $prior ]]; then
    report "Playwright $to was already reported: https://github.com/$repo/actions/runs/$prior"
    if [[ ${GITHUB_EVENT_NAME:-} != workflow_dispatch ]]; then exit 0; fi
  fi
fi

notice=$(cat <<EOF
### Playwright $to is available

- Current driver: \`$from\`
- [Upstream release](https://github.com/microsoft/playwright/releases/tag/v$to), commit \`$sha\`
- [Prepare the port locally](https://github.com/$repo/blob/${GITHUB_SHA:-main}/PORTING.md#bumping-the-pinned-version) with \`TO=$to\` and \`UPSTREAM_SHA=$sha\`.
EOF
)
report "$notice"
if [[ -n ${GITHUB_OUTPUT:-} && -z $prior ]]; then
  printf '%s\n' "$notice" > "$RUNNER_TEMP/upstream-notice.md"
  printf 'notice=%s\n' "$name" >> "$GITHUB_OUTPUT"
fi
