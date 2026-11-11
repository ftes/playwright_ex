# Testing with ExUnit

PlaywrightEx is the library, ExUnit is the test runner. `PlaywrightEx.Test` adds what the
official clients' test plugins (pytest-playwright, Playwright.NUnit) have: a shared browser, a
context and page per test, and traces, screenshots and videos of failures. This guide tests an
app that runs somewhere and is reached through a base URL, whatever it is written in. For Phoenix
feature tests (with the Ecto sandbox), see [Fluffy](https://hex.pm/packages/fluffy). Snippets
alias `PlaywrightEx.{Page, Locator, ...}`.

## Setup

Configure the fragments in `config/test.exs`:

```elixir
# config/test.exs
config :playwright_ex, :test,
  context_options: [base_url: "http://localhost:4000"],
  trace: :retain_on_failure,
  screenshot: :only_on_failure
```

A test module uses `PlaywrightEx.Test` and lists the fragments as setup callbacks:

```elixir
defmodule MyApp.SignUpTest do
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.{Expect, Locator, Page}

  setup_all :browser
  setup [:new_context, :new_page]

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end
end
```

`use PlaywrightEx.Test` goes after `use ExUnit.Case`. It imports the fragments and a `test`
macro that marks the end of each test's body, so `on_exit` knows whether the test passed (ExUnit
reports failures as before). Doctests and other macros' tests count as failed for their
artifacts, and a failure only in an `on_exit` callback counts as passed.

`browser/1` starts the driver and launches the browser on first use; modules with the same
options share it (and one driver hosts every browser type), also with `async: true` (ExUnit
runs those concurrently with each other; a module's own tests run one after another). A context
is a fresh browser profile with its own cookies, storage and cache, so tests don't share state.
The drivers stop after the suite.

Options go in as arguments, merged over the config: `setup_all do: browser(browser_name:
:firefox)`, `setup ctx, do: new_context(ctx, context_options: [locale: "de-DE"])`.
`launch_options` and `context_options` are those of `PlaywrightEx.BrowserType.launch/2` and
`PlaywrightEx.Browser.new_context/2`. `PlaywrightEx.Test` lists them all.

With `base_url`, `goto` and the URL matchers take paths. Actions and navigations wait 30 seconds
by default, and ExUnit's test timeout is 60 seconds; `set_default_timeout/2` makes a stuck action
fail sooner, with a message saying what it waited for. `set_default_navigation_timeout/2` sets
navigations apart.

## A case template

The fragments read the context map and return new keys (`browser`, then `context`, then
`page`), so a case template mixes them with your own setup. It is also where your own tags
become options:

```elixir
# test/support/browser_case.ex
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate
  import PlaywrightEx.Test

  alias PlaywrightEx.BrowserContext

  using do
    quote do
      use PlaywrightEx.Test
      alias PlaywrightEx.{Expect, Locator, Page}
    end
  end

  setup_all :browser

  # `@tag locale: "de-DE"` on a test.
  setup ctx do
    new_context(ctx, context_options: [locale: ctx[:locale] || "en-US"])
  end

  setup %{context: context} = ctx do
    BrowserContext.set_default_timeout(context, 5_000)
    new_page(ctx)
  end
end
```

A `setup_all` of your own that returns `%{browser: _}` replaces `browser/1`, say for a browser
you connect to (`PlaywrightEx.BrowserType.connect/3`).

## Assertions

`PlaywrightEx.Expect` has the web-first assertions: they retry until the page matches or the
timeout passes. The bang forms raise `PlaywrightEx.ExpectError` with the expected and received
values and the call log:

```elixir
Expect.to_have_url!(page, ~r"/dashboard$")
Expect.to_be_visible!(Page.get_by_text(page, "Saved"))
Page.get_by_role(page, :listitem) |> Expect.to_have_count!(3)
Page.locator(page, ".error") |> Expect.not_() |> Expect.to_be_visible!()
```

Prefer them to `assert Locator.text_content!(...) == ...`, which reads once and races the page.
Their timeout is 5 seconds; set it for the suite in `config/test.exs`:

```elixir
config :playwright_ex, :expect, timeout: 10_000
```

Where an `ExUnit.AssertionError` is needed (a helper that rescues only that), wrap the matcher:

```elixir
defmodule MyApp.Assertions do
  @doc "Runs `fun`, re-raising a failed matcher as an `ExUnit.AssertionError`."
  def assert_expect(fun) do
    fun.()
  rescue
    e in PlaywrightEx.ExpectError ->
      reraise ExUnit.AssertionError, [message: Exception.message(e)], __STACKTRACE__
  end
end
```

```elixir
assert_expect(fn -> Expect.to_have_text!(Page.get_by_role(page, :status), "Saved") end)
```

## Logging in once

Log in once per module and start each context from the saved cookies and local storage:

```elixir
setup_all :browser

setup_all %{browser: browser} do
  context = Browser.new_context!(browser, base_url: "http://localhost:4000")
  page = BrowserContext.new_page!(context)
  Page.goto!(page, "/login")
  Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
  Page.get_by_label(page, "Password") |> Locator.fill!("secret")
  Page.get_by_role(page, :button, name: "Log in") |> Locator.click!()
  Expect.to_have_url!(page, ~r"/dashboard$")

  storage_state = BrowserContext.storage_state!(context)
  BrowserContext.close!(context)
  %{storage_state: storage_state}
end

setup ctx, do: new_context(ctx, context_options: [storage_state: ctx.storage_state])
setup :new_page
```

To share the login between modules, `BrowserContext.storage_state!(context, path:
"tmp/auth.json")` also writes it to a file, and `storage_state:` takes that path. An app that keeps
its tokens in IndexedDB (Firebase Authentication) needs `storage_state!(context, indexed_db:
true)`: IndexedDB is not in the state by default. See
[Authentication](https://playwright.dev/python/docs/auth).

## Several users

Each user is a context. A fragment returns plain keys, so a second user is another call,
matched and renamed; a user on another browser gets it from a second `browser/1`:

```elixir
test "two users edit one document", ctx do
  %{context: ada} = new_context(ctx)
  %{context: bob} = new_context(ctx)
  %{browser: firefox} = browser(browser_name: :firefox)
  %{context: eve} = new_context(%{ctx | browser: firefox})

  ada_page = BrowserContext.new_page!(ada)
  bob_page = BrowserContext.new_page!(bob)
  eve_page = BrowserContext.new_page!(eve)
  # ...
end
```

All three contexts are recorded into the test's one trace, and each gets its own video.

## Traces, screenshots and videos

`record_artifacts/2` (started by `new_context/2` with the config, or called in a `setup` with
options) records every context the test creates, also with a plain `Browser.new_context!/2` or in
a `Task`. Each test writes to a dir of its own under `test-results/`, named after the test file
and name, as Playwright Test's `testInfo.outputDir`, and a short hash of the module (and its
`parameterize:` parameters) that tells same-named tests apart:

```
test-results/sign_up-signs-up-5d41a/trace.zip
test-results/sign_up-signs-up-5d41a/test-failed-1.png
```

A failed test also gets Playwright Test's `error-context.md`: its errors, its source and an aria
snapshot of its page, for you or an agent to read.

`trace`, `screenshot` and `video` are `:off` by default, as in Playwright Test.
`:retain_on_failure` (trace, video) and `:only_on_failure` (screenshot) record every test and
keep the files of failures; a passing test's are dropped in its `on_exit`. Open a trace with `mix playwright_ex.cli show-trace
test-results/.../trace.zip`. More in the [Debugging and CI](debugging-and-ci.md) guide.

As in Playwright Test, each takes options too, with the mode as `:mode`: `trace: [mode: :on,
snapshots: false]`, `screenshot: [mode: :only_on_failure, full_page: true]`, `video: [mode: :on,
size: %{width: 640, height: 480}]`. An option given to `record_artifacts/2` replaces the config's
value as a whole.

Tracing slows every test. Playwright Test's answer is to trace only the retry of a failure
(`on-first-retry`); with ExUnit, trace when asked:

```elixir
# config/test.exs
config :playwright_ex, :test, trace: if(System.get_env("TRACE"), do: :on, else: :off)
```

and rerun the failures with tracing in CI:

```sh
mix test || TRACE=1 mix test --failed
```

Passing runs pay nothing for it, and the first run's files stay: nothing is deleted at the start
of a run, so delete `test-results/` yourself. Files of your own go in the test's dir with
`output_path(ctx, "export.csv")`; they stay when the test passes. A flaky test that passes on the rerun leaves no
trace; for those, `:retain_on_failure`.

A context created for the test by another process (a GenServer that runs a user session) is
recorded too when that process gets the test's context map: `new_context(%{ctx | browser:
browser})`, with `record_artifacts/2` in the test's own `setup`.

A trace you start yourself (`Tracing.start!(tracing, sources: true)`) on a shared driver also
gets the stacks and sources of concurrent tests, as the driver adds every call's stack to each
trace on the connection. `record_artifacts/2` filters them out of its `trace.zip`; for your own
traces, use `isolate: true`.

## Isolated modules

A shared browser suits tests that only use contexts. A module that changes the driver or the
browser for everyone (registers selectors, sets the test id attribute, closes or reconnects
the browser) takes one of its own:

```elixir
setup_all ctx, do: browser(ctx, isolate: true)
```

The driver is taken on the module's first `browser(ctx, isolate: true)`, as Playwright Test's
worker-scoped `browser` fixture is lazy, and the module's later calls (in a test, or by a process
given the test's context map) get the same one. So a mixed module calls it in only the tests that
need it. The module holds the driver until its end; it goes to the next module if a test ran and
all passed, else it is discarded. Clean up on it in a test's `on_exit`: a case template's own
`setup_all` `on_exit` runs after the module's end.

Firefox serializes input (mouse, keyboard) across all pages of a browser, so concurrent modules
on a shared Firefox slow each other down. When the whole run is Firefox, use `isolate: true` (up
to `workers` modules at once). For a few Firefox modules in a mixed suite, put them in one ExUnit
group: modules of a group never run at once, so one shared Firefox serves one module at a time
while the others run in parallel. It covers a second user on Firefox inside a test too
(`browser(browser_name: :firefox)`):

```elixir
use ExUnit.Case, async: true, group: :firefox

setup_all do: browser(browser_name: :firefox)
```

That is Playwright Test's model: a driver and its browsers per worker, used by one module at a time
and replaced after a failure. At most `workers` modules hold one at once (config, default half the
schedulers, as Playwright Test's `workers`); the others wait. Shared browsers run on one driver per
`driver` and `on_start`, outside that limit. To set up each new driver (register selectors, say),
pass `on_start: &MyApp.Selectors.register/1`.

## Polling and waiting

When the state shows in the page, assert on the page: `Expect.*` retries. For state elsewhere (an
email, a background job, a record behind an API), retry the assertion. PlaywrightEx has no
`expect.poll` or `toPass`, as those belong to Playwright's test runner; this helper is enough:

```elixir
defmodule MyApp.Eventually do
  @doc "Calls `fun` until it doesn't raise, for up to `timeout` ms, then raises its last error."
  def eventually(fun, timeout \\ 5_000, interval \\ 100) do
    retry(fun, System.monotonic_time(:millisecond) + timeout, interval)
  end

  defp retry(fun, deadline, interval) do
    fun.()
  rescue
    error ->
      if System.monotonic_time(:millisecond) >= deadline, do: reraise(error, __STACKTRACE__)
      Process.sleep(interval)
      retry(fun, deadline, interval)
  end
end
```

```elixir
import MyApp.Eventually

eventually(fn ->
  response = APIRequestContext.get!(BrowserContext.request(context), "/api/exports/1")
  assert APIResponse.json!(response)["status"] == "done"
end)
```

Events forwarded to the test process arrive when the browser emits them, which can be well after
the action that led to them (a request, a timer). `assert_receive` waits only 100 ms by default,
so give it a timeout, or raise the default with `ExUnit.start(assert_receive_timeout: 5_000)`:

```elixir
test_pid = self()
Page.on(page, :console, &send(test_pid, {:console, ConsoleMessage.text(&1)}))
Page.get_by_role(page, :button, name: "Save") |> Locator.click!()
assert_receive {:console, "saved"}, 5_000
```

See [Events and waiting](events-and-waiting.md) for one-off events (downloads, popups, dialogs).
