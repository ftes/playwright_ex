#!/usr/bin/env bash
# Run only in the unprivileged preparation and verification jobs.
set -euo pipefail

upstream=https://github.com/microsoft/playwright.git
stable='^[0-9]+\.[0-9]+\.[0-9]+$'
commit='^[0-9a-f]{40}$'
export PW_UPSTREAM="$RUNNER_TEMP/upstream"
context="$RUNNER_TEMP/pilot-prepared"
paths=(
  packages/playwright-core/src packages/playwright/src packages/playwright/types
  packages/protocol packages/isomorphic packages/utils packages/injected/src utils
  docs/src tests/page tests/library tests/config tests/registry.md
)

tag_commit() {
  local ref="refs/tags/v$2" refs
  refs=$(git ls-remote "$1" "$ref" "$ref^{}")
  awk -v ref="$ref" '$2 == ref {tag=$1} $2 == ref "^{}" {peeled=$1}
    END {print (peeled ? peeled : tag)}' <<< "$refs"
}

fetch_sources() {
  [[ $FROM_SHA =~ $commit && $TO_SHA =~ $commit && $FROM_SHA != "$TO_SHA" ]]
  git init --quiet "$PW_UPSTREAM"
  git -C "$PW_UPSTREAM" fetch --no-tags --depth=1 "$upstream" "$FROM_SHA" "$TO_SHA"
  [[ $(git -C "$PW_UPSTREAM" rev-parse "$FROM_SHA^{commit}") == "$FROM_SHA" ]]
  [[ $(git -C "$PW_UPSTREAM" rev-parse "$TO_SHA^{commit}") == "$TO_SHA" ]]
  git -C "$PW_UPSTREAM" -c core.hooksPath=/dev/null checkout --detach "$TO_SHA"
}

install_deps() {
  mise install erlang elixir
  mise exec -- mix deps.get
  git diff --exit-code HEAD -- mix.lock
  mise exec -- mix deps.compile
}

generate_pins_and_protocol() {
  [[ $TO =~ $stable && $NODE =~ $stable ]]
  mise exec -- mix playwright.checksums "$TO" "$NODE"
  mise exec -- mix run -e 'Playwright.Driver.install(force: true)'
  mise exec -- mix playwright.cli install --with-deps chromium
  mise exec -- mix playwright.gen.protocol "$PW_UPSTREAM"
  cp "$PW_UPSTREAM/tests/registry.md" test/upstream_registry.md
}

case "$1" in
  prepare)
    from=$(<DRIVER_VERSION)
    [[ $from =~ $stable && $TO =~ $stable && $from != "$TO" ]]
    [[ $(printf '%s\n%s\n' "$from" "$TO" | sort -V | tail -1) == "$TO" ]]
    curl -fsSL --retry 3 "https://registry.npmjs.org/playwright-core/$TO" |
      jq -e --arg version "$TO" '.version == $version and (.dist.integrity | startswith("sha512-"))' >/dev/null
    FROM_SHA=$(tag_commit "$upstream" "$from")
    TO_SHA=$(tag_commit "$upstream" "$TO")
    fetch_sources
    NODE=$(<NODE_VERSION)
    python_sha=$(tag_commit https://github.com/microsoft/playwright-python.git "$TO")
    if [[ -n $python_sha ]]; then
      [[ $python_sha =~ $commit ]]
      NODE=$(curl -fsSL --retry 3 "https://raw.githubusercontent.com/microsoft/playwright-python/$python_sha/NODE_VERSION")
    fi
    install_deps
    generate_pins_and_protocol
    mise exec -- mix playwright.gen.api "$PW_UPSTREAM"
    mkdir "$context"
    {
      printf 'Playwright %s (%s) → %s (%s)\n\n' "$from" "$FROM_SHA" "$TO" "$TO_SHA"
      git -C "$PW_UPSTREAM" diff --stat "$FROM_SHA" "$TO_SHA"
      git -C "$PW_UPSTREAM" diff --no-ext-diff --no-textconv "$FROM_SHA" "$TO_SHA" -- "${paths[@]}"
    } > "$context/upstream.diff"
    git -C "$PW_UPSTREAM" archive --format=tar.gz --output="$context/upstream.tar.gz" "$TO_SHA" -- "${paths[@]}"
    # Parity can fail until the semantic port. Preserve diagnostics for the model.
    mise exec -- mix playwright.parity > "$context/parity.txt" 2>&1 || true
    printf 'from-sha=%s\nto-sha=%s\nnode=%s\n' "$FROM_SHA" "$TO_SHA" "$NODE" >> "$GITHUB_OUTPUT"
    ;;
  regenerate)
    fetch_sources
    install_deps
    generate_pins_and_protocol
    # The deterministic scaffold must reproduce byte for byte.
    git diff --exit-code -- DRIVER_VERSION NODE_VERSION priv/driver_checksums.exs \
      lib/playwright/protocol/{validator,metainfo}.ex test/upstream_registry.md
    ;;
  finalize)
    mise exec -- mix playwright.gen.api "$PW_UPSTREAM"
    mise exec -- mix format
    ;;
  check)
    mise exec -- mix format --check-formatted
    mise exec -- mix compile --warnings-as-errors
    mise exec -- mix credo
    mise exec -- mix playwright.parity
    mise exec -- mix test --warnings-as-errors
    ;;
  *) exit 2 ;;
esac
