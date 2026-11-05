# Update playwright_ex to a new upstream Playwright release

You run unattended in GitHub Actions, in a checkout of this repo's default branch. The header
above gives FROM (the pinned upstream version), TO (the new upstream release), VERSION (ours for
it), BRANCH and the RELEASE link. Elixir deps, the FROM driver and chromium are installed.

playwright_ex is a 1:1 port of the Playwright JS client. Read `PORTING.md` (all of it: the rules
decide how every hunk is ported) and `PLAN.md` "Decisions" before changing anything, and study
the existing ported code next to whatever you port.

## Steps

1. `git switch -c BRANCH`. Commit after every coherent step (`git commit -m "<short imperative
   message>"`), so partial work survives.
2. Fetch upstream at both tags (shallow; `git diff` needs only the two trees):
   ```
   git init -q /tmp/playwright
   git -C /tmp/playwright fetch --depth=1 https://github.com/microsoft/playwright tag vFROM tag vTO
   git -C /tmp/playwright diff --stat vFROM vTO -- packages/playwright-core/src/client tests/page tests/library packages/protocol/spec docs/src/api
   ```
   Read the RELEASE notes too (`gh release view vTO --repo microsoft/playwright`).
3. Follow PORTING.md "Bumping the pinned version", step by step:
   1. Bump `@driver_version` in `lib/playwright_ex/driver.ex` to TO. Bump `@node_version` only
      if playwright-python's `NODE_VERSION` changed for TO (look it up in microsoft/playwright-python
      with `gh` or `curl`). Run `mix playwright_ex.checksums`, then
      `mix playwright_ex.install -- chromium` (driver and browser for TO).
   2. `mix playwright_ex.gen.protocol` and `mix playwright_ex.gen.api`; commit the generated diff
      on its own.
   3. Port every hunk of `git -C /tmp/playwright diff vFROM vTO -- packages/playwright-core/src/client
      tests/page tests/library` 1:1, per PORTING's rules: same module per class, upstream order
      and names, `-- not ported: <reason>` / `-- ported as <name>` markers, specs mirrored with
      identical names and order. Never edit the generated facade (`lib/playwright_ex/api/`) by
      hand. Use subagents for independent files when the diff is large.
   4. `mix playwright_ex.parity` until it prints `parity: ok`, handling new, removed and renamed
      upstream files as PORTING says, and refresh `test/upstream_registry.md`.
4. Set `@version` in `mix.exs` to VERSION. Add a `## [VERSION] YYYY-MM-DD` section (today) to
   `CHANGELOG.md` right below `## [Unreleased]`, in the style of the existing ones: "Drive
   Playwright TO" with the RELEASE link, then the API added or changed by the port.
5. Verify; all must pass:
   ```
   mix format
   mix compile --warnings-as-errors
   mix credo
   mix playwright_ex.parity
   mix playwright_ex.gen.api --check
   MIX_ENV=test mix dialyzer --force-check
   mix docs --warnings-as-errors
   mix test --warnings-as-errors   # BROWSER=chromium is set; a failure: rerun once with --failed
   ```
   A failing test the port did not cause (it fails on FROM as well) is reported, not hidden.
6. `git push -u origin BRANCH`, then open a draft PR against `main`:
   `gh pr create --draft --base main --head BRANCH --title "Update to Playwright TO" --body-file <file>`.
   The body, concise: the RELEASE link; the upstream diff stats (files, insertions, deletions of
   client and specs); what was ported, in a few lines; a checklist of what's left (unported
   hunks, skipped specs, decisions to review, anything needing a human); the verification
   results, one line each.

## When the port is too large for one run

Minor releases can touch dozens of files. Port in order of value (client API first, then its
specs). Before you run low on turns or time: commit what's done and keep the build green.
Specs not yet ported get bodiless tests with `@tag skip: "not ported: pending update to TO"`
(and client methods `-- not ported: pending update to TO` markers), so verification passes and
the rest is greppable. Then push and open the PR as in step 6, with the remainder in the
checklist. A draft PR with a green partial port beats no PR.

## Rules

- Never merge, never push to `main` or any branch but BRANCH, never force-push, never edit
  `.github/`.
- Don't edit `PLAN.md` or `DECISIONS.md`; list non-obvious decisions in the PR checklist.
- No attribution anywhere: no `Co-Authored-By` trailers, no "Generated with Claude Code" lines,
  in commits, the PR or comments. The repo owner forbids it.
- Upstream sources come from the release at the pin (`PlaywrightEx.Upstream`, re-downloaded for
  TO by the mix tasks) and `/tmp/playwright`; nothing else is a reference for TO.
