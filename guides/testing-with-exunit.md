# Testing with ExUnit

PlaywrightEx is the library, ExUnit is the test runner. This guide tests an app that runs
somewhere and is reached through a base URL, whatever it is written in. For Phoenix feature tests
(with the Ecto sandbox), see [Fluffy](https://hex.pm/packages/fluffy).

## Setup

Start the driver and launch one browser for the whole run, in `test/test_helper.exs`:

```elixir
{:ok, _} = PlaywrightEx.Supervisor.start_link()

browser =
  PlaywrightEx.playwright()
  |> PlaywrightEx.Playwright.chromium()
  |> PlaywrightEx.BrowserType.launch!()

:persistent_term.put(MyApp.BrowserCase, browser)
ExUnit.start()
```

`test_helper.exs` runs in the process that runs the suite, so the browser lives as long as the
run and closes with it. For a lazy launch and a restart after a crash, keep it in a supervised
process instead; [Fluffy](https://hex.pm/packages/fluffy)'s `BrowserRuntime` is one. A case
template gives each test a fresh context and page of that browser:

```elixir
# test/support/browser_case.ex
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate

  alias PlaywrightEx.{Browser, BrowserContext}

  setup_all do
    %{browser: :persistent_term.get(__MODULE__)}
  end

  setup %{browser: browser} do
    context = Browser.new_context!(browser, base_url: System.get_env("BASE_URL", "http://localhost:4000"))
    BrowserContext.set_default_timeout(context, 5_000)
    on_exit(fn -> BrowserContext.close(context) end)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end
```

A context is a fresh browser profile: its own cookies, storage and cache. Contexts are cheap and
don't share state, so tests share the one browser safely, also across modules with `async: true`
(ExUnit runs those concurrently with each other; a module's own tests run one after another). A
browser per module would only add a browser launch per module. A test:

```elixir
defmodule MyApp.SignUpTest do
  use MyApp.BrowserCase, async: true

  alias PlaywrightEx.{Expect, Locator, Page}

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end
end
```

With `base_url`, `goto` and the URL matchers take paths. Actions and navigations wait 30 seconds
by default, and ExUnit's test timeout is 60 seconds; `set_default_timeout/2` makes a stuck action
fail sooner, with a message saying what it waited for. `set_default_navigation_timeout/2` sets
navigations apart.

## Assertions

`PlaywrightEx.Expect` has the web-first assertions: they retry until the page matches or the
timeout passes. The bang forms raise `ExUnit.AssertionError`, so a failure reads like any other:

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

## Logging in once

Log in once per module and start each context from the saved cookies and local storage:

```elixir
setup_all %{browser: browser} do
  context = Browser.new_context!(browser, base_url: System.get_env("BASE_URL", "http://localhost:4000"))
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
```

The case template's `setup` passes `storage_state: ctx[:storage_state]` to `new_context!`
(see below), so modules that don't log in get an empty context. To share the login between
modules, `BrowserContext.storage_state!(context, path: "tmp/auth.json")` also writes it to a file,
and `storage_state:` takes that path. See [Authentication](https://playwright.dev/python/docs/auth).

## Traces and screenshots of failures

Playwright's test runner and pytest-playwright have options for this (`trace: 'retain-on-failure'`,
`--tracing retain-on-failure`). ExUnit has none, so here are two recipes.

### Trace on rerun

The simpler and faster one: trace only when asked, and rerun the failures with tracing. The case
template's `setup` (alias `Tracing` too):

```elixir
setup %{browser: browser} = ctx do
  context = Browser.new_context!(browser, base_url: System.get_env("BASE_URL", "http://localhost:4000"))
  BrowserContext.set_default_timeout(context, 5_000)
  on_exit(fn -> BrowserContext.close(context) end)

  if System.get_env("TRACE") do
    tracing = BrowserContext.tracing(context)
    Tracing.start!(tracing, screenshots: true, snapshots: true, sources: true)
    on_exit(fn -> Tracing.stop(tracing, path: Path.join(artifacts_dir(ctx.module, ctx.test), "trace.zip")) end)
  end

  %{context: context, page: BrowserContext.new_page!(context)}
end

def artifacts_dir(module, test) do
  Path.join(["tmp/test-results", inspect(module), String.replace(to_string(test), ~r/\W+/, "_")])
end
```

`on_exit/1` callbacks run in reverse order, so the trace is written before the context closes. In
CI:

```sh
mix test || TRACE=1 mix test --failed
```

Passing runs pay nothing for tracing. A flaky test that passes on the rerun leaves no trace,
though; for those, retain on failure.

### Retain on failure

Like the test runners' `retain-on-failure`: trace every test, write the trace and a screenshot in
`on_exit/1`, and delete those of passing tests. `on_exit/1` doesn't know whether the test failed,
but a formatter does, and ExUnit runs `on_exit/1` before it reports the test. The case template's
`setup`, with the login state:

```elixir
setup %{browser: browser} = ctx do
  context =
    Browser.new_context!(browser,
      base_url: System.get_env("BASE_URL", "http://localhost:4000"),
      storage_state: ctx[:storage_state]
    )

  BrowserContext.set_default_timeout(context, 5_000)
  page = BrowserContext.new_page!(context)
  tracing = BrowserContext.tracing(context)
  Tracing.start!(tracing, screenshots: true, snapshots: true, sources: true)
  dir = artifacts_dir(ctx.module, ctx.test)

  on_exit(fn ->
    Page.screenshot(page, path: Path.join(dir, "failure.png"))
    Tracing.stop(tracing, path: Path.join(dir, "trace.zip"))
    BrowserContext.close(context)
  end)

  %{context: context, page: page}
end
```

The formatter:

```elixir
# test/support/retain_on_failure.ex
defmodule MyApp.RetainOnFailure do
  @moduledoc "An ExUnit formatter that deletes the artifacts of passing tests (retain-on-failure)."
  use GenServer

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: nil} = test}, state) do
    File.rm_rf!(MyApp.BrowserCase.artifacts_dir(test.module, test.name))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
```

```elixir
# test/test_helper.exs
ExUnit.start(formatters: [ExUnit.CLIFormatter, MyApp.RetainOnFailure])
```

Open a trace with `mix playwright_ex.cli show-trace tmp/test-results/.../trace.zip`. More in the
[Debugging and CI](debugging-and-ci.md) guide.

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
the action that led to them (a request, a timer). `assert_receive` waits only 100 ms by default, so give it a timeout,
or raise the default with `ExUnit.start(assert_receive_timeout: 5_000)`:

```elixir
test_pid = self()
Page.on(page, :console, &send(test_pid, {:console, ConsoleMessage.text(&1)}))
Page.get_by_role(page, :button, name: "Save") |> Locator.click!()
assert_receive {:console, "saved"}, 5_000
```

See [Events and waiting](events-and-waiting.md) for one-off events (downloads, popups, dialogs).
