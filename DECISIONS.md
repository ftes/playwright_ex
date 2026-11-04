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

## 2026-11-04: Direction check 1 (fresh reviewer, read-only)

Verdict: on track, client modules 1:1 statement for statement. Follow-ups taken:
- **Facade `nil` vs JS defaults**: the facade passes omitted optional positional args as `nil`,
  so client `\\` defaults never fire. Idiom (PORTING.md): apply JS defaults in the body; JS
  `null` is `:null`, `undefined` is `nil`. Fixes for `dispatch_event`, `selectOption(null)`,
  `description("")` go with the ElementHandle step.
- **Parity enforces upstream order** (longest common subsequence of method names vs the TS
  file, of test names vs the spec). Only module-level marker lines count. Why: order keeps
  `git diff vA vB` hunks portable.
- **Known gap**: `record_har`/`expose_functions` are in the facade but raise at runtime (the
  context is created before `recordHar` raises). Fixed by porting HAR/bindings, not by hiding
  the options.

## 2026-11-04: Input, Dialog, ConsoleMessage, WebError, Worker (workstream B)

- **JS readonly fields are client functions** (`Page.keyboard/1`, `mouse/1`, `touchscreen/1`
  under `# readonly properties`), as `Playwright.chromium/1`: the generator needs an arity-1 export.
- **`inspect(console_message)` is `#PlaywrightEx.ConsoleMessage<text>`**, like handles and
  locators; upstream's `util.inspect` shows the bare text. The upstream test asserts the
  wrapped form with a deviation comment. Revisit if exact upstream output matters.
- **Assertions inside listeners** become `send` to the test process plus `assert_received`;
  JS `void dialog.accept()` is a non-bang `Dialog.accept/1` inside the listener.
- **Mac-only upstream tests** skip by `:os.type()` at compile time.

## 2026-11-04: waitForEvent, urlMatch, promise handles (workstream C)

Review these first: they shape the public API.
- **Promise handles**: a JS async member returns a `PlaywrightEx.Promise` when the Python
  client has an `expect_*` for it (`wait_for_event`, `wait_for_navigation`, `wait_for_request`,
  `wait_for_response` on Page/Frame/BrowserContext). No bang form; block with
  `Promise.await!(Page.wait_for_navigation(page))`. The wait is registered before the call
  returns (heap promise started under the baton); any process can await it, any number of
  times; an unawaited one ends when it settles or times out. Revisit: a blocking
  `wait_for_navigation!`?
- **Callback forms** for every Python `expect_*` (`expect_popup(page, action, opts)`,
  `expect_event(page, event, action, opts)`, `expect_request(page, url_or_predicate, action,
  opts)`): action before options (C#'s order); action exceptions propagate (C#); error names
  are the started member's (`page.waitForEvent`). Emitted only when the result class is
  ported. The generator also loads the Python view of the docs for these.
- **`wait_for_event` takes Python's arguments** (`event`, options `predicate`/`timeout`), not
  JS `optionsOrPredicate`. Deviation from the JS signature; `event` accepts atoms.
- **Function URL matchers get the URL string**, not a parsed URL (Python, Java, .NET).
  `URLPattern` is dropped from api.json unions (no Elixir counterpart).
- **`LocalUtils.glob_to_regex` caches the driver's regex** per {glob, baseURL, ws}
  (Elixir-only helper; PLAN Decisions: globs via the driver).
- **`@events` emitted at the top of each generated module**, so `event` args accept atoms.

## 2026-11-04: ElementHandle, JSHandle, setInputFiles (workstream A)

- **`JSHandle`/`ElementHandle` `toString` is `String.Chars`** (`"#{handle}"` is the preview,
  pure ETS read, no baton). Revisit with `Locator.toString`.
- **Subclass dispatch**: `JSHandle.as_element/1` dispatches on the struct (JS virtual call);
  the generator types `PlaywrightEx.JSHandle.t()` as `%JSHandle{} | %ElementHandle{}` and does
  not duplicate inherited members into the ElementHandle facade (as api.json).
- **`ElementHandle.inputValue` has no options** (`@dropped_options`): docs list `timeout`, the
  JS client takes none (same as `$eval`).
- **`WritableStream.stream/1` returns a `Collectable`** (`Enum.into(File.stream!(...), ...)`
  for `stream.pipeline`); remote `lastModifiedMs` has whole-second precision (Erlang stat).
- **Test deviations, commented**: `(function(){})` needs a `() =>` wrapper (no `isFunction`,
  PLAN); circular `jsonValue` is `%{"b" => :circular}`; missing-file error lacks "ENOENT:";
  `waitFor`/`visibility` `as any` options assert the facade's `ArgumentError`, so
  "should tolerate waitFor=visible" expects an error where upstream expects none.
- **`test/support/utils.ex`** ports `tests/config/utils.ts` (`attach_frame`, `verify_viewport`, ...).
