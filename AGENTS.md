# Playwright

A statement-by-statement port of the Playwright JS client to Elixir. The rules are in
[`PORTING.md`](PORTING.md) (how to port) and [`docs/architecture.md`](docs/architecture.md) (why).
Read them before changing ported code. When reviewing a change or fixing review findings, follow
[Reviewing](CONTRIBUTING.md#reviewing).

- Names: the modules are `Playwright.*`, the app `:playwright` (`config :playwright`,
  `mix playwright.*`); only the Hex package and the GitHub repo are `playwright_ex`.
- Deviate only where the port requires it. For an edge case upstream's client shares, keep
  upstream's behaviour, even when it looks wrong, and don't add a special case.
- Docs (moduledocs, guides, CHANGELOG, `docs/architecture.md`) describe what this code does.
  Write "as upstream" only after checking both upstream at the pin and our code. Where they
  differ, say so as a deviation or under "Not ported yet", never as upstream's behaviour.
- Upstream's sources at the pin (client, server, injected script, specs, API docs) are the
  reference: `mix playwright.upstream` (part of `mix setup`) downloads them and prints their
  directory, `<cache_dir>/<version>/upstream`.
- `Playwright.Test` (ExUnit runner and browser pool, `lib/playwright/test*`) is a native runner, with no
  port markers. Only what the ported matchers, traces and failure reports need is ported:
  testInfo, `test.trace`, `step`, errorContext and the github and json reporters
  (`Playwright.Test.{TestInfo, TestTracing, ErrorContext, GitHubFormatter, JSONFormatter}`, `test.ex`), with upstream source
  references and `-- not ported`/`# deviation:` comments, but no `@upstream`: parity covers the
  client API, not the runner.
- CHANGELOG during an RC phase: prefix entries that only matter to users of an earlier RC with
  `**RC only:**`. These are fixes for bugs an RC introduced, and changes to APIs first shipped in
  an RC. Upstream driver bumps and changes ported from upstream are never RC only. `## [Unreleased]`
  gathers every RC's entries; at the first non-RC release, drop the RC-only ones.
- Several PRs for one goal go in a GitHub stack: `ci.yml` runs Build and lint and the tests only
  on a stack's top PR, and not on drafts. Open drafts, each `--base` the previous branch, run
  `gh stack link --base main <bottom> … <top>` (a `--base` chain alone isn't a stack), then mark
  ready top first.
- `mix check` is the full verification: `mix lint` (format, credo, compile, usage rules, Hex package
  compile, docs, dialyzer), then parity and the tests.
- The compatibility floor is Elixir 1.18 on OTP 27 (`.tool-versions.oldest`), which CI's oldest
  lane runs with `mix.lock.oldest`. There are no runtime dependencies, so that lock holds only the
  dev and test ones the lane builds with; a newer one in `mix.lock` can't break the floor. A new
  runtime dependency goes into `mix.lock.oldest` at its floor; a test checks they match.
- Files marked "do not edit manually" are generated: run `mix playwright.gen.api`
  (`mix playwright.gen.protocol` for the protocol) instead of editing them.
- `.agents/skills` (linked from `.claude/skills`) is generated: after updating deps run
  `mix usage_rules.sync --yes`; `mix check` fails when it's stale. On Renovate's PRs a workflow
  commits it.
- No attribution anywhere: no `Co-Authored-By` trailers or "Generated with" lines.
