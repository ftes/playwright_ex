# Update the port to a new upstream Playwright release

This repo is a 1:1 port of the Playwright JS client. Read `PORTING.md` (all of it) and
`docs/architecture.md`, then study the existing code alongside each upstream change.

1. Compare vFROM and vTO using `git -C` with the absolute path to the supplied snapshot of
   upstream. Read the release notes. Get the diff stats for the upstream client, matchers and
   specs, and read the diffs in `packages/playwright-core/src/client`, `packages/playwright/src/matchers`,
   `tests/page`, `tests/library`, `packages/protocol/spec` and `docs/src/api`.
2. Follow `PORTING.md`'s “Bumping the pinned version”. Start with `mix playwright.checksums TO NODE`
   (use Playwright's Node version at TO if it changed), then `mix playwright.install chromium`.
   Update the driver and generated files even when none of the upstream code changes apply.
3. Port client, matcher, spec and runner hunks. `mix playwright.runner_sources` lists the runner
   files. Use subagents for independent files if the diff is large. Leave `@version` alone:
   the release PR sets it. Add the upstream release link and port changes under `## [Unreleased]`
   in `CHANGELOG.md`.
4. Verify `mix format`, `mix compile --warnings-as-errors`, `mix credo`,
   `mix playwright.parity`, `mix playwright.gen.api --check` and
   `mix test --warnings-as-errors`. Chromium is installed; for a failing test, rerun once
   with `--failed`. Report unrelated failures rather than weakening coverage.
5. Return `publish` and a concise draft PR body: release link, upstream diff stats, what was
   ported, runner features adopted or skipped, a checklist of the remainder, and verification.

If the port is too large for one run, keep the build green and report the remaining work in
the checklist. Mark pending specs with `@tag skip: "not ported: pending update to TO"` and
pending client methods with `-- not ported: pending update to TO`, as described in `PORTING.md`.
Don't edit workflows or agent configuration. Don't merge or rebase.
