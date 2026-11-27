#!/usr/bin/env bash
# Resolve release refs once, then fetch exact commits in each unprivileged job.
set -euo pipefail

js=https://github.com/microsoft/playwright.git
python=https://github.com/microsoft/playwright-python.git
version='^[0-9]+\.[0-9]+\.[0-9]+$'
sha='^[0-9a-f]{40}$'

release_sha() {
  local ref="refs/tags/v$2" refs
  refs=$(git ls-remote "$1" "$ref" "$ref^{}")
  awk -v ref="$ref" '$2 == ref {tag=$1} $2 == ref "^{}" {peeled=$1}
    END {print (peeled ? peeled : tag)}' <<< "$refs"
}

case "$1" in
  resolve)
    [[ $FROM =~ $version && $TO =~ $version ]]
    js_from=$(release_sha "$js" "$FROM")
    js_to=$(release_sha "$js" "$TO")
    [[ $js_from =~ $sha && $js_to =~ $sha && $js_from != "$js_to" ]]
    node=$(<NODE_VERSION)
    python_sha=$(release_sha "$python" "$TO")
    if [[ -n $python_sha ]]; then
      [[ $python_sha =~ $sha ]]
      node=$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/microsoft/playwright-python/$python_sha/NODE_VERSION")
    fi
    [[ $node =~ $version ]]
    printf 'from-sha=%s\nto-sha=%s\nnode=%s\n' "$js_from" "$js_to" "$node" >> "$GITHUB_OUTPUT"
    ;;
  fetch)
    [[ $FROM_SHA =~ $sha && $TO_SHA =~ $sha ]]
    PW_UPSTREAM=${PW_UPSTREAM:-"$RUNNER_TEMP/playwright-source"}
    git init -q "$PW_UPSTREAM"
    git -C "$PW_UPSTREAM" fetch --no-tags --depth=1 "$js" "$FROM_SHA" "$TO_SHA"
    git -C "$PW_UPSTREAM" checkout --detach "$TO_SHA"
    [[ $(git -C "$PW_UPSTREAM" rev-parse HEAD) == "$TO_SHA" ]]
    [[ $(git -C "$PW_UPSTREAM" rev-parse "$FROM_SHA^{commit}") == "$FROM_SHA" ]]
    ;;
  *) exit 2 ;;
esac
