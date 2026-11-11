# Update playwright_ex to a new upstream Playwright release

You run unattended in GitHub Actions, in a checkout of this repo's default branch. The header
above gives FROM (the pinned upstream version), TO (the new upstream release), VERSION (ours for
it), BRANCH and the RELEASE link. Elixir deps, the FROM driver and chromium are installed.

playwright_ex is a 1:1 port of the Playwright JS client. Read `PORTING.md` (all of it: the rules
decide how every hunk is ported) and `docs/architecture.md` before changing anything, and study
the existing ported code next to whatever you port.

## Steps

1. `git switch -c BRANCH`. Commit after every coherent step (`git commit -m "<short imperative
   message>"`), and once the PR exists (step 3.2) run `git push origin BRANCH` after every commit,
   so partial work survives and is visible.
2. Fetch upstream at both tags (shallow; `git diff` needs only the two trees):
   ```
   git init -q /tmp/playwright
   git -C /tmp/playwright fetch --depth=1 https://github.com/microsoft/playwright tag vFROM tag vTO
   git -C /tmp/playwright diff --stat vFROM vTO -- packages/playwright-core/src/client tests/page tests/library packages/protocol/spec docs/src/api
   ```
   Read the RELEASE notes too (`gh release view vTO --repo microsoft/playwright`).
3. Follow PORTING.md "Bumping the pinned version", step by step:
   1. Run `mix playwright_ex.checksums TO NODE`: it writes `DRIVER_VERSION`, `NODE_VERSION` and
      the checksums. NODE is the current `NODE_VERSION`, or playwright-python's `NODE_VERSION`
      for TO if that changed (look it up in microsoft/playwright-python with `gh` or `curl`). Then
      `mix playwright_ex.install -- chromium` (driver and browser for TO).
   2. `mix playwright_ex.gen.protocol` and `mix playwright_ex.gen.api`; commit the generated diff
      on its own. Then publish, before porting anything, so a run that stops early still leaves
      its work on a PR:
      ```
      git push -u origin BRANCH
      gh pr create --draft --base main --head BRANCH --title "Update to Playwright TO" --body "Port in progress."
      ```
   3. Port every hunk of `git -C /tmp/playwright diff vFROM vTO -- packages/playwright-core/src/client
      tests/page tests/library` 1:1, per PORTING's rules: same module per class, upstream order
      and names, `-- not ported: <reason>` / `-- ported as <name>` markers, specs mirrored with
      identical names and order. Never edit the generated facade (`lib/playwright_ex/api/`) by
      hand. Use subagents for independent files when the diff is large.
   4. `mix playwright_ex.parity` until it prints `parity: ok`, handling new, removed and renamed
      upstream files as PORTING says, and refresh `test/upstream_registry.md`.
   5. Read `git -C /tmp/playwright diff vFROM vTO -- 'docs/src/*.md' ':!docs/src/api'` (upstream's
      guides) and update `guides/` where it adds a pattern or caveat they should mention; list
      anything you left out in the PR body.
   6. Re-check the `env:`/`flaky:` skips and PORTING's "Upstream issues to re-check" as PORTING
      step 6 says; drop skips that pass and list them in the PR body.
4. Leave `@version` in `mix.exs` alone (releases are 0.17 candidates until versions mirror
   Playwright; GH #126). Under `## [Unreleased]` in `CHANGELOG.md`, in the style of the
   existing entries: "Drive Playwright TO" with the RELEASE link, then the API added or changed by
   the port.
5. Verify; all must pass (CI on the PR runs Dialyzer, the docs build and the other browsers):
   ```
   mix format
   mix compile --warnings-as-errors
   mix credo
   mix playwright_ex.parity
   mix playwright_ex.gen.api --check
   mix test --warnings-as-errors   # BROWSER=chromium is set; a failure: rerun once with --failed
   ```
   A failing test the port did not cause (it fails on FROM as well) is reported, not hidden.
6. Push the last commit and replace the PR's placeholder body, leaving it a draft:
   `gh pr edit BRANCH --body-file <file>`.
   The body, concise: the RELEASE link; the upstream diff stats (files, insertions, deletions of
   client and specs); what was ported, in a few lines; a checklist of what's left (unported
   hunks, skipped specs, decisions to review, anything needing a human); the verification
   results, one line each.

## When the port is too large for one run

Minor releases can touch dozens of files. Port in order of value (client API first, then its
specs). Before you run low on turns or time: commit what's done and keep the build green.
Specs not yet ported get bodiless tests with `@tag skip: "not ported: pending update to TO"`
(and client methods `-- not ported: pending update to TO` markers), so verification passes and
the rest is greppable. Then push and replace the PR body as in step 6, with the remainder in the
checklist. A draft PR with a green partial port beats no PR.

## Rules

- Never merge, never push to `main` or any branch but BRANCH, never force-push, never edit
  `.github/`.
- List non-obvious decisions in the PR checklist.
- Use your file tools, not Bash, to read and search files, and keep any scratch files under tmp/;
  run each allowed Bash command on its own, without cd, ;, &&, pipes or heredocs (you are already
  in the repository).
- No attribution anywhere: no `Co-Authored-By` trailers, no "Generated with Claude Code" lines,
  in commits, the PR or comments. The repo owner forbids it.
- Upstream sources come from the release at the pin (`PlaywrightEx.Upstream`, re-downloaded for
  TO by the mix tasks) and `/tmp/playwright`; nothing else is a reference for TO.
