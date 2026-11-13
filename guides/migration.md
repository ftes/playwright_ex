# Migrating from 0.16

PlaywrightEx is now a 1:1 port of the official JavaScript client, and its public API is generated
from Playwright's own docs. The [playwright.dev](https://playwright.dev/docs/api/class-playwright)
docs apply: `page.getByRole(...)` is `PlaywrightEx.Page.get_by_role/3`, `locator.click()` is
`PlaywrightEx.Locator.click/2`, `expect(locator).toBeVisible()` is
`PlaywrightEx.Expect.to_be_visible/2`.

This is a clean cut: the guid-based modules, `Selector`, `EventWaiter`, `launch_browser/2`,
`subscribe/2` and `JsLogger` are gone. This guide covers the changes from 0.16, including those
of the release candidates. From an earlier release, also read the [changelog](../CHANGELOG.md)
up to 0.16. Snippets below alias `PlaywrightEx.{Page, Locator, ...}`.

## Handles, not guids

Functions take and return structs (`%PlaywrightEx.Page{}`, typed `PlaywrightEx.Page.t()`). Each
handle knows its connection, so there is no `connection:` option.

```elixir
# before
{:ok, page} = BrowserContext.new_page(context.guid, timeout: 1000)
{:ok, _} = Frame.goto(page.main_frame.guid, url: "/", timeout: 1000)

# after
page = BrowserContext.new_page!(context)
Page.goto!(page, "/")
```

A `timeout:` per call is no longer needed: set defaults once
([Timeouts](introduction/getting-started.md#timeouts)). How JS calls read in Elixir (results,
options, enums, promises and `expect_*`, events, assertions, errors) is in
[From playwright.dev to Elixir](introduction/api-conventions.md); listeners and processes in
[Concurrency](concurrency.md).

## Mapping

### Launch and connect

```elixir
# before
{PlaywrightEx.Supervisor, timeout: 1000, js_logger: MyLogger, executable: "node_modules/.bin/playwright"}
{:ok, browser} = PlaywrightEx.launch_browser(:chromium, headless: true, timeout: 1000)
{:ok, context} = Browser.new_context(browser.guid, base_url: url, timeout: 1000)
{:ok, page} = BrowserContext.new_page(context.guid, timeout: 1000)

# after
{PlaywrightEx.Supervisor, name: MyApp.Playwright}
playwright = PlaywrightEx.playwright(MyApp.Playwright)
browser = BrowserType.launch!(Playwright.chromium(playwright), headless: true)
context = Browser.new_context!(browser, base_url: url)
page = BrowserContext.new_page!(context)
```

- The driver (Node and `playwright-core`) is pinned and downloaded on first start, or with
  `mix playwright_ex.install` (`-- chromium firefox --with-deps` for CI), so the npm `playwright`
  package can go. Its version (`PlaywrightEx.Driver.version/0`) may be newer than the one you ran:
  read Playwright's [release notes](https://playwright.dev/docs/release-notes) (1.65 breaks some
  tests: actions wait for the element to be not inert, cookie matching follows RFC 6265, and text
  the browser doesn't render leaves accessible names). `executable:`
  takes a Playwright 1.65 CLI such as `node_modules/.bin/playwright`, not `cli.js`: a path (not
  looked up in `$PATH`), whose version nothing checks.
- Prefer `only: [:dev, :test]` to `only: :test`, so that the mix tasks and `mix usage_rules.sync`
  (PlaywrightEx ships `usage-rules.md`) work in `:dev` ([Installation](introduction/getting-started.md#installation)).
- The supervisor's `timeout:`, `js_logger:`, `ws_endpoint:` and `fail_on_unknown_opts:` options
  are gone (unknown options raise); `env:` stays. Its `connection_name/1` and the `connection:`
  option are replaced by `PlaywrightEx.playwright(name)`. Its default name is `PlaywrightEx` (was
  `PlaywrightEx.Supervisor`), and its child id is its `:name`, so drivers of different names can
  share a supervision tree.
- `ws_endpoint:` becomes `BrowserType.connect!(Playwright.chromium(playwright), "ws://localhost:3000/")`,
  through the local driver (no `websockex`), with a server on the driver's version
  ([Remote browsers](debugging-and-ci.md#remote-browsers)). `connect_over_cdp/3` works too.
- `mix playwright_ex.install --no-browsers` installs only the driver, for a browser launched with
  `executable_path:` or `channel:`.
- The driver is cached under `:filename.basedir(:user_cache, "playwright_ex")`, moved with
  `PLAYWRIGHT_EX_CACHE_DIR` or the supervisor's `cache_dir:`; cache it in CI
  ([GitHub Actions](debugging-and-ci.md#github-actions)).
- `minimum_supported_version/0`: `PlaywrightEx.Driver.version/0`.

### Context, page, navigation

| Before | After |
| --- | --- |
| `Browser.close(browser.guid, timeout: t)` | `Browser.close(browser)` |
| `BrowserContext.close(ctx.guid, ...)` | `BrowserContext.close(context)` |
| `page.main_frame.guid` | `Page.main_frame(page)`; most `Frame` functions also exist on `Page` |
| `Frame.goto(frame, url: u)` | `Page.goto(page, u)` (returns the `Response` or `nil`) |
| `Page.reload(page.guid)` | `Page.reload(page)` |
| `Frame.title`, `Frame.content` | `Page.title/1`, `Page.content/2` |
| `Frame.wait_for_url(frame, url: u)` | `Page.wait_for_url(page, u)` or `Expect.to_have_url(page, u)` |
| `Frame.snapshot/2`, `Frame.document_request/2` | `Page.url/1`; `on(:response)` for navigation requests |
| `Request.response(guid)`, `Connection.initializer!` | `Request.response/1`, accessors (`Request.url/1`, `Response.status/1`, ...) |
| `BrowserContext.add_cookies(ctx, cookies: cs)` | `BrowserContext.add_cookies(context, cs)` |
| `BrowserContext.register_selector_engine` | `Selectors.register(Playwright.selectors(playwright), name, %{content: js})`, once per driver (a second `register` fails) |
| `BrowserContext.clock_install`, `clock_fast_forward` | `Clock.install(BrowserContext.clock(context))`, `Clock.fast_forward/2` |
| `BrowserContext.credentials_*` | `Credentials.*` on `BrowserContext.credentials(context)` |
| `Page.mouse_move/down/up` | `Mouse.move/4`, `down/2`, `up/2` on `Page.mouse(page)` |
| `ElementHandle.*`, `FilePayload` | `ElementHandle.*`, but `evaluate` and `dispose` are `JSHandle.evaluate/4`, `JSHandle.dispose/1`; payloads are `%{name:, mimeType:, buffer:}` |
| `Download.from_event/2`, `Artifact.*` | `Download.save_as/2`, `Download.delete/1`; traces take `path:` (below), videos `Video.save_as/2` |
| `PlaywrightEx.send(msg, opts)` | none: every protocol call has a facade function |

Calls not listed (`cookies`, `storage_state`, `add_init_script`, `unroute_all`,
`wait_for_load_state`, `bring_to_front`, ...) keep their names and take the struct. What JS takes
as arguments becomes positional, the rest stays options: `cookies(context, urls)`,
`add_init_script(context, script)`, `Page.wait_for_load_state(page, :load)`.
`unsubscribe` and `update_subscription` go with subscriptions (below), and
`route`'s `on_error:` is gone.

### Selectors to locators

`Selector` strings become `Locator`s. Locators are lazy, chain, and auto-wait.

```elixir
# before
selector = Selector.css(".flash") |> Selector.concat(Selector.text("Deleted", exact: false))
{:ok, _} = Frame.click(frame.guid, selector: Selector.button("Delete"), timeout: 1000)
{:ok, _} = Frame.fill(frame.guid, selector: Selector.label("Email"), value: "ada@example.com")

# after
flash = Page.locator(page, ".flash") |> Locator.filter(has_text: "Deleted")
Page.get_by_role(page, :button, name: "Delete") |> Locator.click!()
Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
```

| `Selector` | `Locator` |
| --- | --- |
| `css(s)`, `concat(a, b)` | `Page.locator(page, s)`, `Locator.locator(a, b)` |
| `text(t, exact: e)`, `label/2` | `get_by_text(_, t, exact: e)`, `get_by_label/3` |
| `role(r, name)`, `button/2`, `link/2`, `menuitem/2` | `get_by_role(_, :button, name: name)` (the role is an atom) |
| `and/2`, `has/2` | `Locator.and_/2`, `Locator.filter(_, has: l)` |
| `at(n)` | `Locator.nth/2`, `first/1`, `last/1` |
| `visible/2` | `Locator.filter(_, visible: true)` |
| `any_frame/1` | `Page.frame_locator/2`, `Locator.content_frame/1` |

`Page.locator/3` passes raw selectors through, so existing strings (custom engines, `internal:`)
keep working while you migrate: `Page.locator(page, "css=.flash >> internal:text=\"Deleted\"i")`.

### Input

| Before (`Frame.*` with `selector:`) | After (`Locator.*`) |
| --- | --- |
| `click`, `hover`, `focus`, `blur` | `click/2`, `hover/2`, `focus/2`, `blur/2` |
| `fill(value: v)`, `select_option(options: o)` | `fill/3`, `select_option/3` |
| `check`, `uncheck` | `check/2`, `uncheck/2`, `set_checked/3` |
| `type(text: t)`, `press(key: k)` | `press_sequentially/3`, `press/3` |
| `set_input_files(local_paths: ps)` | `set_input_files/3` (paths or payload maps) |
| `drag_and_drop(source:, target:)` | `Locator.drag_to/3` |
| `wait_for_selector` | `Locator.wait_for/2` |
| `is_*`, `inner_html`, `inner_text`, `text_content`, `input_value`, `get_attribute`, `dispatch_event`, `aria_snapshot_json` | same names on `Locator` |
| `Frame.expect(expression: "to.be.visible")`, `expect_result` | `Expect.to_be_visible/2`, ... |
| `Page.expect_url`, `Page.expect_screenshot` | `Expect.to_have_url/3`, `Expect.to_have_screenshot/2` |

```elixir
# before
{:ok, true} = Frame.expect(frame.guid, expression: "to.have.count", selector: "li", expected_number: 2)

# after
Expect.to_have_count!(Page.locator(page, "li"), 2)
Expect.to_have_title!(page, "Home")
```

### Evaluate

The expression is JS source; a function receives the optional argument.

```elixir
# before
{:ok, path} = Frame.evaluate(frame.guid, expression: "() => location.pathname", is_function: true)
{:ok, text} = Locator.evaluate(frame.guid, selector: "button", expression: "el => el.textContent", is_function: true)

# after
path = Page.evaluate!(page, "() => location.pathname")
sum = Page.evaluate!(page, "([a, b]) => a + b", [1, 2])
text = Page.locator(page, "button") |> Locator.evaluate!("el => el.textContent")
```

`wait_for_function` follows suit: `Frame.wait_for_function(frame.guid, expression: e, is_function: true, arg: a, polling: "raf")`
becomes `Page.wait_for_function(page, e, a, polling: :raf)` (or `Frame.wait_for_function/4`), and returns a
`JSHandle` of the truthy value.

### Events, `subscribe/2`, `EventWaiter`

No subscriptions, no `{:playwright_msg, _}` messages, no event GenServers:
`on/3` enables the event and passes the listener the event object.

```elixir
# before
{:ok, _} = Page.update_subscription(page.guid, event: :console, enabled: true)
PlaywrightEx.subscribe(context.guid)
receive do: ({:playwright_msg, %{method: :console} = msg} -> msg)

{:ok, pending} = EventWaiter.arm(page.guid, :file_chooser, timeout: 1000)
{:ok, _} = Frame.click(frame.guid, selector: "#upload")
{:ok, _event} = EventWaiter.await(pending)

# after
owner = self()
Page.on(page, :console, fn msg -> send(owner, {:console, ConsoleMessage.text(msg)}) end)

chooser = Page.expect_file_chooser!(page, fn -> Locator.click!(Page.locator(page, "#upload")) end)
FileChooser.set_files!(chooser, path)
```

[Events and waiting](events-and-waiting.md) covers `expect_*` and `wait_for_*`. EventWaiter's
`:predicate` is their predicate, and its `:transform` is code after the await.

```elixir
# before
{:ok, pending} = Page.expect_download(page.guid, timeout: 1000)
{:ok, _} = Frame.click(frame.guid, selector: "a#export")
{:ok, download} = Page.await_download(pending)
:ok = Download.save_as(download, path, timeout: 5000)

# after
download = Page.expect_download!(page, fn -> Locator.click!(Page.locator(page, "a#export")) end)
Download.suggested_filename(download)
:ok = Download.save_as(download, path)
```

### JsLogger

Replace the `js_logger:` module with listeners. `:console` covers console messages,
`:web_error` (on the context) uncaught errors:

```elixir
owner = self()
BrowserContext.on(context, :console, &send(owner, {:console, &1}))
BrowserContext.on(context, :web_error, &send(owner, {:web_error, &1}))

# in the owner (e.g. a GenServer's handle_info/2)
def handle_info({:console, msg}, state) do
  %{url: url, lineNumber: line} = ConsoleMessage.location(msg)
  Logger.log(level(ConsoleMessage.type(msg)), "#{ConsoleMessage.text(msg)} (#{url}:#{line})")
  {:noreply, state}
end

def handle_info({:web_error, error}, state) do
  Logger.error(Exception.message(WebError.error(error)))
  {:noreply, state}
end
```

### Dialogs

```elixir
# before
{:ok, _} = Page.update_subscription(page.guid, event: :dialog, enabled: true)
# ... an EventListener matching %{method: :__create__, params: %{type: "Dialog"}}
{:ok, _} = Dialog.accept(guid, prompt_text: "42", timeout: 1000)

# after
Page.on(page, :dialog, fn dialog ->
  if Dialog.message(dialog) == "Enter the magic number",
    do: Dialog.accept(dialog, "42"),
    else: Dialog.dismiss(dialog)
end)
```

A dialog listener must accept or dismiss (it may call Playwright). Remove it with
`Page.off(page, :dialog, fun)`; without a listener dialogs are dismissed.

### Network and routing

Handlers take `fn route ->` or `fn route, request ->`; call `fulfill/2`, `continue/2`,
`abort/2` or `fallback/2`. Globs, regexes and predicates match as in JS.

```elixir
# before
{:ok, _} = Page.route(page.guid, "**/api/profile", fn route, _request ->
  {:ok, _} = Route.fulfill(route, json: %{name: "Ada"})
end, timeout: 1000)
{:ok, _} = Page.unroute(page.guid, "**/api/profile", timeout: 1000)

# after
Page.route!(page, "**/api/profile", fn route -> Route.fulfill(route, json: %{name: "Ada"}) end)
Page.route!(page, "**/*.png", &Route.abort/1)
Page.unroute!(page, "**/api/profile")
```

`fulfill/2` takes `status:`, `headers:` (a map), `content_type:`, `body:` (`{:binary, b}` for bytes),
`json:`, `path:`; `response:` merges an `APIResponse` from `Route.fetch/2`.

### Tracing and screenshots

```elixir
# before
{:ok, _} = Tracing.tracing_start(context.tracing.guid, screenshots: true, snapshots: true)
{:ok, _} = Tracing.tracing_start_chunk(tracing_id)
Tracing.group(tracing_id, [name: "sign in", location: loc], fn -> ... end)
{:ok, zip} = Tracing.tracing_stop_chunk(tracing_id)
File.cp!(zip.absolute_path, file)
{:ok, png} = Page.screenshot(page.guid, full_page: true, timeout: 1000)

# after
tracing = BrowserContext.tracing(context)
Tracing.start!(tracing, screenshots: true, snapshots: true)
Tracing.start_chunk!(tracing)
Tracing.group!(tracing, "sign in", location: %{file: __ENV__.file, line: __ENV__.line})
# ...
Tracing.group_end!(tracing)
Tracing.stop_chunk!(tracing, path: file)
png = Page.screenshot!(page, full_page: true)
Expect.to_have_screenshot!(page, path: "test/screenshots/home.png")
```

Open a trace with `mix playwright_ex.cli show-trace trace.zip` (forwards any args to the
Playwright CLI).

### Errors

Errors are exceptions named after the JS classes ([Errors](introduction/api-conventions.md#errors)
lists them), with the JS message (API name prefix and call log) and a `log` field:

```elixir
# before
{:error, %{error: %{name: "TimeoutError", message: message}}} = Frame.click(frame.guid, selector: "#x", timeout: 100)

# after
alias PlaywrightEx.TimeoutError
{:error, %TimeoutError{message: "locator.click: Timeout 100ms exceeded" <> _, log: log}} =
  Page.locator(page, "#x") |> Locator.click(timeout: 100)
```

Calls without a `timeout:` (`close`, `evaluate`, `save_as`) are bounded by the caller when needed,
for example in cleanup code:

```elixir
task = Task.async(fn -> BrowserContext.close(context) end)
Task.yield(task, 5_000) || Task.shutdown(task)
```

Calls with a `timeout:` also take a `signal:` (a JS `AbortSignal`), so that another process can
cancel them with a `PlaywrightEx.AbortController`. As in JS, a controller is global: its signal
works with calls on any driver.

```elixir
controller = AbortController.new()
Task.start(fn -> Process.sleep(1_000); AbortController.abort(controller, "user cancelled") end)

{:error, %AbortError{cause: "user cancelled"}} =
  Page.locator(page, "#x") |> Locator.click(signal: AbortController.signal(controller), timeout: 0)
```

## Behaviour changes

- `timeout: 0` means no timeout (as in JS), not "don't wait", and `:infinity` is the same
  (`wait_for_timeout/2` rejects it: its argument is how long to wait). To check without waiting,
  read once (`Locator.is_visible/2`, `Locator.count/1`) or pass a short timeout.
- Nested maps use the JS keys both ways: `add_cookies` takes `%{sameSite: "Strict", httpOnly: true}`,
  and `cookies`, `storage_state` and the other results return them (`sameSite`, `localStorage`),
  where 0.16 converted to and from snake_case. A snake_case key raises `ArgumentError`
  (`record_har: %{url_filter: ...}`), except in maps passed through unchecked (cookies, storage
  state), where it is ignored: `same_site:` sets nothing. Enum values in them are the JS strings
  (`sameSite: "Lax"`), not `:lax` or `"lax"` as 0.16 accepted.
- JS `null` is `:null` and `undefined` is `nil` (`evaluate`, `aria_snapshot_json`); 0.16 returned
  `nil` for both. A `null` in an optional field of a storage-state file (`"sameSite": null`) fails
  validation, as upstream.
- Other `evaluate` values changed too: `-Infinity` is `:neg_infinity` (was `:negative_infinity`),
  `-0` is `-0.0` (was `:negative_zero`), a JS `Error` is a `JSError` exception (was a map),
  typed arrays are lists of numbers (was `%{type:, data:}`), a circular reference is `:circular`
  (was `{:circular_reference, id}`).
- Tuple forms return `{:error, e}` only for Playwright's errors (`t:PlaywrightEx.error/0`);
  misuse such as a bad argument raises in both forms.
- Failed bang matchers raise `PlaywrightEx.ExpectError`, not `ExUnit.AssertionError`
  ([Testing with ExUnit](testing-with-exunit.md#assertions)).
- A lost driver closes its pages, contexts and browsers (`close`, `disconnected`), its waits fail
  with `PlaywrightEx.TargetClosedError` instead of hanging, and `PlaywrightEx.playwright/1` waits
  for the restarted driver.
- An unknown key of `config :playwright_ex` (other than `:test`, `:expect` and a module's), and
  an invalid `:test`, `:expect` or `PlaywrightEx.Test.GitHubFormatter` config, raise at
  application start.
- Dialogs without a listener are dismissed instead of blocking the page.
- Error messages start with the API name (`locator.click: ...`).
- `Tracing.start/2` no longer takes `coverage:`.
- Unknown options raise `ArgumentError` instead of being passed through (the
  `:fail_on_unknown_opts` config is gone).
- Each API call logs at `:debug` ([Logging](introduction/getting-started.md#logging)).
- Local file errors (a missing `set_input_files` file or `path:`) raise Elixir's `File.Error` (as
  `Route.fulfill(path:)` did before), not a driver error. A storage-state file that can't be read
  raises `PlaywrightEx.PlaywrightError` ("Error reading storage state from ..."), with the
  `File.Error` as its `:cause`.
- Strings are literal text (or globs, for URLs), never patterns. A `Regex` passed where JS takes a
  `RegExp` is sent to the browser or driver as a JS regex; `PlaywrightEx.RegExp` lists what raises
  `ArgumentError` and takes JS-only syntax. JS regexes returned by `evaluate` are always a
  `PlaywrightEx.RegExp` (lossless); `PlaywrightEx.RegExp.to_regex/1` (or `compile!/1`) gives a
  `Regex` when PCRE can run it.

## Known gaps

- Not ported: `launchServer`, `connectOverCDP` with a transport, `toMatchSnapshot`.
