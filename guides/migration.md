# Migrating to 1.64

PlaywrightEx 1.64 is a 1:1 port of the official JavaScript client, and its public API is
generated from Playwright's own docs. Versions follow Playwright (1.64.x drives Playwright 1.64).
The [playwright.dev](https://playwright.dev/docs/api/class-playwright) docs apply: `page.getByRole(...)`
is `PlaywrightEx.Page.get_by_role/3`, `locator.click()` is `PlaywrightEx.Locator.click/2`,
`expect(locator).toBeVisible()` is `PlaywrightEx.Expect.to_be_visible/2`.

This is a clean cut: the guid-based modules, `Selector`, `EventWaiter`, `launch_browser/2`,
`subscribe/2` and `JsLogger` are gone. Snippets below alias `PlaywrightEx.{Page, Locator, ...}`.

## Concepts

**Handles, not guids.** Functions take and return structs (`%PlaywrightEx.Client.Page{}`, typed
`PlaywrightEx.Page.t()`). Each handle knows its connection, so there is no `connection:` option.

```elixir
# before
{:ok, page} = BrowserContext.new_page(context.guid, timeout: 1000)
{:ok, _} = Frame.goto(page.main_frame.guid, url: "/", timeout: 1000)

# after
page = BrowserContext.new_page!(context)
Page.goto!(page, "/")
```

**`{:ok, v}` or bang.** Every async member has `name/n` returning `{:ok, value} | {:error, exception}`
(`:ok` for void ones) and `name!/n` that raises. Sync members (`Page.url/1`, `Page.locator/3`,
`Locator.filter/2`, `Page.mouse/1`) return plain values.

**Options.** Keyword lists (or maps) with snake_case keys, validated: unknown keys and enum values
raise `ArgumentError`. Nested objects are maps with the JS keys, the same shape results come
back in (`%{name: "a", value: "b", sameSite: "Lax"}`). Enums are atoms (`get_by_role(page, :button)`).

**Timeouts.** Set defaults once instead of a `timeout:` per call:

```elixir
BrowserContext.set_default_timeout(context, 5_000)
BrowserContext.set_default_navigation_timeout(context, 10_000)
```

`timeout:` remains on the members that have it in JS. Matchers default to 5 s.

**Events.** `on/3`, `once/3` and `off/3` take a listener function, as in JS. Listeners run while
holding the driver's baton (see below), so keep them short; `send/2` to the owning process is the
safe default. For one event, use a promise handle or the `expect_*` callback form:

```elixir
promise = Page.wait_for_event(page, :popup)
Locator.click!(Page.get_by_text(page, "Open"))
popup = PlaywrightEx.Promise.await!(promise)

{:ok, popup} = Page.expect_popup(page, fn -> Locator.click!(Page.get_by_text(page, "Open")) end)
```

**Assertions.** `PlaywrightEx.Expect` has the web-first matchers. They retry, return
`:ok | {:error, %ExpectError{}}`, and the bang forms raise `ExUnit.AssertionError`.

**Promises.** `wait_for_*` members return a `PlaywrightEx.Promise`: the wait starts before the
call returns, and any process can `await/1` it.

**The baton.** One driver runs one JS-like event loop: only one process runs client code at a time
and yields while it awaits. Calls from many processes still overlap. A listener or route handler
that blocks on non-Playwright work stalls the whole driver, as in JS.

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
  `mix playwright_ex.install` (`-- chromium firefox --with-deps` for CI). `executable:` still
  points at an npm-managed CLI if you prefer that.
- The supervisor's `connection_name/1` and the `connection:` option are replaced by
  `PlaywrightEx.playwright(name)`.
- `ws_endpoint:` becomes `BrowserType.connect!(Playwright.chromium(playwright), "ws://localhost:3000/")`,
  through the local driver (no `websockex`). `connect_over_cdp/3` works too.
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
| `ElementHandle.*`, `FilePayload` | `ElementHandle.*`; payloads are `%{name:, mimeType:, buffer:}` |
| `PlaywrightEx.send(msg, opts)` | none: every protocol call has a facade function |

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
| `role(r, name)`, `button/2`, `link/2` | `get_by_role(_, :button, name: name)` |
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
| `is_visible`, `inner_html`, `text_content`, `input_value`, `get_attribute` | same names on `Locator` |
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

`expect_*` exists where the Python client has one (`expect_popup`, `expect_download`,
`expect_request`, `expect_response`, `expect_navigation`, `expect_event`, ...); the matching
`wait_for_*` returns a `PlaywrightEx.Promise`. EventWaiter's `:predicate` is the `predicate:`
option; its `:transform` is code after the await.

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

Errors are exceptions named after the JS classes, with the JS message (API name prefix and call
log) and a `log` field:

```elixir
# before
{:error, %{error: %{name: "TimeoutError", message: message}}} = Frame.click(frame.guid, selector: "#x", timeout: 100)

# after
alias PlaywrightEx.Client.Errors.TimeoutError
{:error, %TimeoutError{message: "locator.click: Timeout 100ms exceeded" <> _, log: log}} =
  Page.locator(page, "#x") |> Locator.click(timeout: 100)
```

Calls without a `timeout:` (`close`, `evaluate`, `save_as`) are bounded by the caller when needed,
for example in cleanup code:

```elixir
task = Task.async(fn -> BrowserContext.close(context) end)
Task.yield(task, 5_000) || Task.shutdown(task)
```

## Behaviour changes

- `timeout: 0` means no timeout (as in JS), not "don't wait". `:infinity` is accepted too.
- Dialogs without a listener are dismissed instead of blocking the page.
- Error messages start with the API name (`locator.click: ...`).
- `Tracing.start/2` no longer takes `coverage:`.
- Unknown options raise `ArgumentError` instead of being passed through.

## Known gaps

- `signal:` (AbortSignal) options are not supported.
- No `logger:` launch/context option, no public setting for the 5 s matcher timeout.
- Not ported: `launchServer`, `connectOverCDP` with a transport, `toPass`, `expect.poll`,
  soft assertions, file-based aria snapshots, `toMatchSnapshot`.
- `inspect(locator)` and locators in matcher messages show JS syntax and raw selectors.
