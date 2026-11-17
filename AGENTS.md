# Playwright

A statement-by-statement port of the Playwright JS client to Elixir. The rules are in
[`PORTING.md`](PORTING.md) (how to port) and [`docs/architecture.md`](docs/architecture.md) (why).
Read them before changing ported code. When reviewing a change or fixing review findings, follow
[Reviewing](README.md#reviewing).

- Names: the modules are `Playwright.*`, the app `:playwright` (`config :playwright`,
  `mix playwright.*`); only the Hex package and the GitHub repo are `playwright_ex`.
- Deviate only where the port requires it. For an edge case upstream's client shares, keep
  upstream's behaviour, even when it looks wrong, and don't add a special case.
- Upstream's sources at the pin (client, server, injected script, specs, API docs) are the
  reference: `mix playwright.upstream` (part of `mix setup`) downloads them and prints their
  directory, `<cache_dir>/<version>/upstream`.
- `Playwright.Test` (ExUnit runner and browser pool, `lib/playwright/test*`) is a native runner, with no
  port markers. Only what the ported matchers and traces need is ported: testInfo, `test.trace`
  and `step` (`Playwright.Test.{TestInfo, TestTracing}`, `test.ex`), with upstream source
  references and `-- not ported`/`# deviation:` comments, but no `@upstream`: parity covers the
  client API, not the runner.
- CHANGELOG during an RC phase: prefix entries that only matter to users of an earlier RC with
  `**RC only:**`. These are fixes for bugs an RC introduced, and changes to APIs first shipped in
  an RC. Upstream driver bumps and changes ported from upstream are never RC only. At the first
  non-RC release, drop the RC-only entries and merge the RC sections into that release's notes,
  keeping the latest `Drives Playwright` line.
- `mix check` is the full verification (format, credo, compile, dialyzer, parity, tests).
- Files marked "do not edit manually" are generated: run `mix playwright.gen.api`
  (`mix playwright.gen.protocol` for the protocol) instead of editing them.
- `.agents/skills` (linked from `.claude/skills`) is generated: after updating deps run
  `mix usage_rules.sync --yes`; `mix check` fails when it's stale. On Renovate's PRs a workflow
  commits it.
- No attribution anywhere: no `Co-Authored-By` trailers or "Generated with" lines.
