[![Hex.pm Version](https://img.shields.io/hexpm/v/playwright_ex)](https://hex.pm/packages/playwright_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/playwright_ex/)
[![License](https://img.shields.io/hexpm/l/playwright_ex.svg)](https://github.com/ftes/playwright_ex/blob/main/LICENSE.md)
[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/ftes/playwright_ex/elixir.yml)](https://github.com/ftes/playwright_ex/actions)

# PlaywrightEx

Elixir client for the Playwright node.js server.

Automate browsers like Chromium, Firefox, Safari and Edge.
Helpful for web scraping and agentic AI.

Please [get in touch](https://ftes.de) with feedback of any shape and size.

Enjoy!

Freddy.

## Getting started
1. Add dependency
        # mix.exs
        {:playwright_ex, "~> 0.12"}

2. Ensure Playwright 1.63 or newer is installed (executable in `$PATH` or installed via `npm`)

3. Start connection (or add to supervision tree)
        # if installed via npm or similar add `executable: "assets/node_modules/playwright/cli.js"`
        {:ok, _} = PlaywrightEx.Supervisor.start_link(timeout: 1000)

4. Use it
        alias PlaywrightEx.{Browser, BrowserContext, Frame}

        {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: 1000)
        {:ok, context} = Browser.new_context(browser.guid, timeout: 1000)

        {:ok, %{main_frame: frame}} = BrowserContext.new_page(context.guid, timeout: 1000)
        {:ok, _} = Frame.goto(frame.guid, "https://elixir-lang.org/", timeout: 1000)
        {:ok, _} = Frame.click(frame.guid, Selector.link("Install"), timeout: 1000)

## JavaScript logging

Pass a module implementing `PlaywrightEx.JsLogger` as the `:js_logger` supervisor
option to log browser console messages and uncaught JavaScript errors.
Both `nil` (the default) and `false` disable logging without affecting event
delivery to subscribers.

## Remote server via WebSocket
By default, PlaywrightEx launches a local playwright driver.
This is typically installed via `npm` or `bun`.

Alternatively, PlaywrightEx can connect to a remote playwright server:

      # mix.exs
      {:websockex, "~> 0.4"}

  ```
  docker run -p 3000:3000 --rm --init -it \\
    mcr.microsoft.com/playwright:v1.63.0-noble \\
    npx -y playwright@1.63.0 run-server --port 3000 --host 0.0.0.0
  ```

      {:ok, _} = PlaywrightEx.Supervisor.start_link(
        timeout: 1000,
        ws_endpoint: "ws://localhost:3000?browser=chromium"
      )

## API Layers
Most channel functions are thin protocol wrappers.
In ExDoc, composed helpers are grouped under `Client-Composed Functions`.

Frame URL/load-state waits return synchronously and check recorded state first.
URL predicate errors propagate to that wait's caller without affecting other waits.

## Timeouts

Pass a `:timeout` for each operation: a positive number of milliseconds,
`0` for no waiting, or `:infinity` to disable the timeout.

With `0`, browser commands time out without being sent. Frame URL/load-state
waits check the current recorded state once.

## Request responses

Retrieve the response for a known request without subscribing to response events:

```elixir
{:ok, response} = PlaywrightEx.Request.response(request.guid, timeout: 1_000)
```

The result is a response handle (`%{guid: response_id}`), or `nil` if the request
fails without a response. Read its metadata with
`PlaywrightEx.Connection.initializer!(connection, response_id)`.
Each request in a redirect chain has its own response.

Use `PlaywrightEx.Frame.document_request/2` to read the request for the frame's
current committed document. Same-document navigation preserves it; a new
navigation replaces it with the committed request, including after redirects.
The result is `nil` when no request was recorded.

`Frame.snapshot/2` returns the recorded URL, document request, and a client-generated
`document_ref` in one read. The reference changes on new documents, including
reloads, and remains stable across same-document navigation.

`EventWaiter` automatically enables opt-in Page and BrowserContext events while
waiting. Predicates filter raw events; an optional `:transform` maps the accepted
event inside the task, for example to save metadata before the channel closes.

## Request routing

Replace external resources while keeping real script tags and application code:

```elixir
alias PlaywrightEx.{Page, Route}

{:ok, _} = Page.route(page.guid, "**/forms/js.php/**", fn route, _request ->
  Route.fulfill(route,
    content_type: "application/javascript",
    body: "window.Formstack = { submit: () => 'acknowledged' };"
  )
end, connection: connection, timeout: 5_000)

# Navigate normally; callbacks run independently of the navigating process.
```

Use `BrowserContext.route/4` to cover all pages, including popup initial requests.
Each page or context supports **one active handler**. Registering another returns
`{:error, %{reason: :route_already_registered}}`; remove the existing one first.
Matching page handlers take precedence over context handlers. `Route.continue/2`
goes straight to the network, bypassing context handlers. `Route.abort/2` cancels
the request. Handles inherit the registration connection and timeout.

The driver matches Playwright globs (`*`, `**`, `{a,b}`, backslash escapes), with
its normal base-URL resolution. `?` is literal. Regexes, handler chains,
`fallback`, `times`, and wait/ignore-errors removal modes are deferred.

`Route.fulfill/2` accepts `:status`, `:headers`, `:content_type`, and one of binary
`:body`, `:json`, or local `:path`. JSON is encoded automatically. Files infer
content type from the extension and are read on the Elixir host, even with a
remote browser. `:content_type` overrides the default. `:response` is deferred.

```elixir
Route.fulfill(route, json: %{ok: true})
Route.fulfill(route, path: "test/fixtures/formstack_stub.js")
```

Resolve each request **inside its callback, before returning**. Returning without
resolution is a failure. Callback exceptions/exits propagate through an OTP link
to the registering process, normally failing an ExUnit test automatically. The
connection and registrations owned by other processes remain unaffected. Pattern match
on `{:ok, _}` inside callbacks to turn operation errors into callback failures.

For an application that needs isolated error reporting, opt into
`on_error: :message` at registration. Failures then abort the unresolved request
and send `{:playwright_route_error, %{guid: guid, matcher: glob, reason: reason}}`
to the registering process, while leaving the handler installed.

`Page.unroute(page.guid, glob, timeout: 5_000)` removes a matching registration;
an optional callback argument restricts removal to that function.
`Page.unroute_all(page.guid, timeout: 5_000)` removes it unconditionally.
Context equivalents work the same way. Removal **cancels active callbacks and
aborts unresolved requests**, unlike Playwright.js's removal policies. Handles
cannot be passed to other processes or retained after callbacks return.
Registration and callbacks also end when their owner, target, or connection
exits. Normal removal/closure does not fail the registering process.

Routing disables HTTP caching. Service Workers can bypass interception; pass
`service_workers: "block"` to `Browser.new_context/2` when testing such resources.
See the [Playwright routing documentation](https://playwright.dev/docs/api/class-page#page-route).

## Downloads

Arm the listener, trigger the download, then await its event. Use `after` to
release the listener if the action fails:

```elixir
alias PlaywrightEx.{Download, EventWaiter, Frame, Page}

{:ok, pending} = Page.expect_download(page.guid, timeout: 1_000)

try do
  {:ok, _} = Frame.click(frame.guid, selector: "a#export", timeout: 1_000)
  {:ok, download} = Page.await_download(pending)

  download.suggested_filename # e.g. "report.csv"
  download.url
  :ok = Download.save_as(download, "downloads/report.csv", timeout: 5_000)
after
  EventWaiter.cancel(pending)
end
```

The event means the download has **started**. `Download.save_as/3` waits for
completion, works locally and over WebSocket, and preserves the source artifact.
It creates parent directories and preserves an existing destination if saving fails.
You own saved files. The browser deletes its source artifacts when the context
closes; use `Download.delete/2` to delete a source earlier.

Event capture, the triggering action, and saving each have their own timeout.
The event timeout starts when arming begins and is not restarted by awaiting
later or skipping events. The save timeout covers the whole transfer.

Use an optional predicate when an action produces several downloads, or to
select a filename or URL among unrelated downloads:

```elixir
{:ok, pending} = Page.expect_download(page.guid,
  timeout: 1_000,
  predicate: &(&1.suggested_filename == "report.csv")
)
```

The predicate receives a `Download`. Keep it quick and nonblocking; exceptions
propagate to the calling process.

## References
- Code extracted from [phoenix_test_playwright](https://hexdocs.pm/phoenix_test_playwright).
- Inspired by [playwright-elixir](https://hexdocs.pm/playwright).
- Official playwright node.js [client docs](https://playwright.dev/docs/intro).

## Comparison to playwright-elixir
`playwright-elixir` built on the python client and tried to provide a comprehensive client from the start.
`playwright_ex` instead is a ground-up implementation. It is not intended to be comprehensive. Rather, it is intended to be simple and easy to extend.

## Contributing

To run the tests locally, you'll need to:

1. Check out the repo
2. Run `mix setup`. This will take care of setting up your dependencies, installing the JavaScript dependencies (including Playwright), and compiling the assets.
3. Run `mix test` or, for a more thorough check that matches what we test in CI, run `mix check`.
4. Run `mix test.websocket` to run all tests against a 'remote' playwright server via websocket. Docker needs to be installed. A container is started via `testcontainers`.
