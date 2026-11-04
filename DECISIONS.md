# Decisions log

Decisions taken while porting autonomously, newest last, for review. The durable design is in
`PLAN.md` (a reviewed decision moves there or gets reverted); conventions in `PORTING.md`.
Each entry: what, why, and what to revisit.

## 2026-11-04: Locators on Frame/Page

- **`$`-names and reserved words take Python's names**, in client and facade: `$eval` is
  `eval_on_selector`, `$$eval` `eval_on_selector_all`, `$`/`$$` `query_selector(_all)`, `and`/`or`
  are `and_`/`or_` (rename map in `gen.api`, `ported as` markers in the client). Why: not valid
  Elixir function names; Python is the closest official precedent.
- **`$eval` has no options in the facade** (`ApiRules` `@dropped_options`). The docs list
  `strict`, but the JS client asserts at most 3 arguments, so a 1:1 client can't take it.
- **`inspect(locator)` shows the raw selector** (`#PlaywrightEx.Locator<internal:role=button>`);
  `Locator.toString` is not ported yet. Why: rendering needs the driver
  (`LocalUtils.asLocatorDescription`), and `inspect` must work without the baton. Revisit with
  PLAN "Then" item 4 (port `locatorGenerators`).
- **`Locator.description/1` reads `internal:describe` with a regex**, not `parseSelector`:
  `describe/2` always appends it as a JSON string at the end. Revisit if the selector parser
  gets ported.
- **`kAnyFrameSelector` is a constant in `Client.Locator`** instead of porting `selectorParser`.
- **The test id attribute name is a `:persistent_term`**: module state in JS, shared by all
  connections, so not per loop.
- **`Client.ElementHandle` started with only `convertSelectOptionValues`**, so its facade is
  generated with every member listed as not ported.
- **Upstream `TODO:` comments become `Upstream to-do:`**: `mix credo` (CI) fails on TODO tags.
