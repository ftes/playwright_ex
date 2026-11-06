# From playwright.dev to Elixir

The API is generated from Playwright's docs, so playwright.dev describes every function here, and
the function docs are upstream's. This page shows how a JS call reads in Elixir. The
[Python docs](https://playwright.dev/python/docs/api/class-playwright) are the closest read: their
names, keyword options and `expect_*` helpers are ours.

Snippets here and in the function docs alias the modules they use:
`alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page, ...}`.

## Names

A JS class is a module, a method is a function that takes the object first, and calls chain
with pipes:

```elixir
# await page.getByRole('button', { name: 'Save' }).click();
Page.get_by_role(page, :button, name: "Save") |> Locator.click!()
```

Objects are structs (`%PlaywrightEx.Page{}`, typed `PlaywrightEx.Page.t()`). Names are
snake_case. Where a JS name is no Elixir name, Python's is used: `$eval` is
`Page.eval_on_selector/4`, `and`/`or` are `Locator.and_/2` and `Locator.or_/2`, `not` is
`not_to_*` (see [Assertions](#assertions)). Properties are functions too: `page.keyboard` is
`Page.keyboard(page)`, `request.url()` is `Request.url(request)`.

Predicates keep Python's names, `Locator.is_visible/2` and `Browser.is_connected/1`, not
`visible?`: a `?` function returns a plain boolean, and most of these are calls with a tuple and a
bang form (`{:ok, true} = Locator.is_visible(locator)`, `true = Locator.is_visible!(locator)`).

## Results: tuple or bang

Each call that JS awaits has two forms. `name/n` returns `{:ok, value}` or
`{:error, exception}` (`:ok` when JS returns nothing), `name!/n` returns the value or raises.
`exception` is one of the errors a JS promise rejects with (`t:PlaywrightEx.error/0`, see
[Errors](#errors)); a bug or a misuse, such as an unknown option, raises in both forms. Calls JS
doesn't await (`page.url()`, `page.locator()`, `locator.filter()`) return plain values.

```elixir
title = Page.title!(page)

case Page.goto(page, "/admin") do
  {:ok, response} -> Response.status(response)
  {:error, %PlaywrightEx.TimeoutError{}} -> :timeout
end
```

Use the bang forms in scripts and tests, the tuple forms where a failure is an expected outcome.
Where JS docs say a call throws, the function docs say it *fails* (with a `TimeoutError`, say):
the tuple form returns the error, the bang form raises it.

## Options

The JS options object is the last argument: a keyword list (or a map) with snake_case keys.

```elixir
# await page.screenshot({ path: 'shot.png', fullPage: true });
Page.screenshot!(page, path: "shot.png", full_page: true)
```

Unknown keys and enum values raise `ArgumentError` before anything is sent. Nested objects are
maps with the JS keys, the shape results come back in, so a result can be passed back as is.
Header maps have string keys.

```elixir
context = Browser.new_context!(browser, viewport: %{width: 1280, height: 720})

BrowserContext.add_cookies!(context, [
  %{name: "session", value: "abc", url: "https://example.com", sameSite: "Lax"}
])

[%{name: "session", sameSite: "Lax"}] = BrowserContext.cookies!(context)
Page.set_extra_http_headers!(page, %{"x-request-id" => "42"})
```

## Enums, `nil` and `:null`

String enums are atoms, snake_case: `'button'` is `:button`, `'no-preference'` is
`:no_preference`. Event names are atoms the same way: `'requestfailed'` is `:request_failed`,
`'websocket'` is `:web_socket`. JS `undefined` is `nil`, so `nil` means "not given"; JS `null` is
`:null`:

```elixir
Page.emulate_media!(page, color_scheme: :dark)
# page.emulateMedia({ colorScheme: null }): back to the browser's default
Page.emulate_media!(page, color_scheme: :null)
```

`evaluate` and `json` results follow the same rule.

## Optional arguments

Optional positional arguments stay positional, options come last. The options may take the place
of an optional argument before them:

```elixir
Page.wait_for_load_state!(page, :networkidle)
Page.wait_for_load_state!(page, timeout: 1_000)
Expect.to_have_attribute!(locator, "disabled", timeout: 1_000)
```

## Waiting for events: promises and `expect_*`

JS starts a wait, acts, then awaits the wait:

```js
const popupPromise = page.waitForEvent('popup');
await page.getByText('Open').click();
const popup = await popupPromise;
```

`wait_for_*` returns a `PlaywrightEx.Promise` for this. The wait is set up when the call returns,
and any process can await it:

```elixir
promise = Page.wait_for_event(page, :popup)
Page.get_by_text(page, "Open") |> Locator.click!()
popup = PlaywrightEx.Promise.await!(promise)
```

The callback form, Python's `with page.expect_popup()`, does the same in one call:

```elixir
popup = Page.expect_popup!(page, fn -> Page.get_by_text(page, "Open") |> Locator.click!() end)
```

`expect_*` exists where Python has one (`expect_download`, `expect_request`, `expect_response`,
`expect_navigation`, `expect_event`, ...). A predicate, JS `waitForEvent(event, predicate)`, goes
in place of the options or as `predicate:`:

```elixir
ready = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "ready"))
```

The bang forms (`Page.wait_for_event!/3`) await at once, so they miss what the code before them
triggered. Start the wait before the action, and keep the bang forms for what happens later on
its own.

## Events

`on/3`, `once/3` and `off/3` take a listener function, as in JS. A listener runs in a process of
its own, and the connection dispatches the next driver message only once the listener returns or
awaits a Playwright call. Keep it short and send the work to the process that owns it:

```elixir
owner = self()
Page.on(page, :console, fn msg -> send(owner, {:console, ConsoleMessage.text(msg)}) end)
```

A listener may call Playwright, as a `:dialog` listener calls `Dialog.accept/2`. The
[Concurrency](../concurrency.md) guide covers ordering, blocking listeners and promise lifetimes.

## Assertions

`expect(x).toY(...)` is `Expect.to_y(x, ...)`, and `expect(x).not.toY(...)` is
`Expect.not_to_y(x, ...)` or `x |> Expect.not_() |> Expect.to_y(...)`:

```elixir
# await expect(page.getByText('Saved')).toBeVisible();
Expect.to_be_visible!(Page.get_by_text(page, "Saved"))
# await expect(locator).not.toHaveText('Error');
Expect.not_to_have_text!(locator, "Error")
locator |> Expect.not_() |> Expect.to_have_text!("Error")
```

Matchers retry until they pass or time out (5 seconds, `config :playwright_ex, :expect`). They
return `:ok` or `{:error, %PlaywrightEx.ExpectError{}}`; the bang forms raise
`ExUnit.AssertionError`, so a failed one fails an ExUnit test as `assert` does (where ExUnit
isn't loaded, they raise the `PlaywrightEx.ExpectError`). Unknown keys in the `:expect` config
raise `ArgumentError`.

## Errors

Errors are exceptions named after the JS classes: `PlaywrightEx.PlaywrightError` (JS `Error`),
`PlaywrightEx.TimeoutError`, `PlaywrightEx.TargetClosedError`, `PlaywrightEx.AbortError` and
`PlaywrightEx.ExpectError`. Where the JS client throws a plain `new Error(message)` itself, it is
a `RuntimeError`; local file errors are `File.Error`. `t:PlaywrightEx.error/0` lists them all.
The message is JS's, starting with the API name, and `log` holds the call log:

```elixir
{:error, %TimeoutError{message: "locator.click: Timeout 100ms exceeded" <> _, log: log}} =
  Page.locator(page, "#missing") |> Locator.click(timeout: 100)
```

## Regular expressions

Where JS takes a `RegExp`, pass a `Regex`; it is sent to the browser as a JS regex. Strings are
always literal text (or globs, for URLs), never patterns:

```elixir
Page.get_by_role(page, :button, name: ~r/submit/i)
Expect.to_have_url!(page, ~r"/dashboard$")
```

PCRE-only syntax JS cannot run (`\A`, possessive quantifiers, inline `(?i)`, ...) raises
`ArgumentError`. For JS-only syntax, pass a `PlaywrightEx.RegExp`:

```elixir
Page.get_by_text(page, PlaywrightEx.RegExp.new("a[^]b", "v"))
```

## `evaluate` takes JS source

The script is a JS string: an expression, or a function that gets the optional argument.

```elixir
Page.evaluate!(page, "document.title")
Page.evaluate!(page, "([a, b]) => a + b", [1, 2])
Page.locator(page, "button") |> Locator.evaluate!("el => el.textContent")
```

Values cross as Elixir terms: JS objects come back as maps with string keys, `Date` is
`DateTime`, `RegExp` is `PlaywrightEx.RegExp`, `NaN` and `Infinity` are `:nan` and `:infinity`,
`undefined` is `nil` and `null` is `:null`.
