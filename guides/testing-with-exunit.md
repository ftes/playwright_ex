# Testing with ExUnit

PlaywrightEx is the library, ExUnit is the test runner. `PlaywrightEx.Test` adds what Playwright
Test's worker gives each test: a browser, a fresh context with Playwright Test's defaults, and
traces, screenshots and videos of failures. This guide tests an app that runs somewhere and is
reached through a base URL, whatever it is written in. For Phoenix feature tests (with the Ecto
sandbox), see [Fluffy](https://hex.pm/packages/fluffy). Snippets alias `PlaywrightEx.{Page,
Locator, ...}`.

## Setup

Configure the runner in `config/test.exs`:

```elixir
# config/test.exs
config :playwright_ex, :test,
  context_options: [base_url: "http://localhost:4000"],
  trace: :retain_on_failure,
  screenshot: :only_on_failure
```

A test module uses `PlaywrightEx.Case`, which gives each test a `context` and a `page`:

```elixir
defmodule MyApp.SignUpTest do
  use PlaywrightEx.Case, async: true

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end
end
```

`PlaywrightEx.Case` is a case template of three pieces, the same as:

```elixir
use ExUnit.Case, async: true
use PlaywrightEx.Test
alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page}
alias PlaywrightEx.Test.BrowserPool

setup do
  context = Browser.new_context!(BrowserPool.shared())
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

`use PlaywrightEx.Test` goes after `use ExUnit.Case`. It registers each test, so the contexts it
creates get Playwright Test's defaults and are recorded, and imports a `test` macro that marks
the end of each test's body, so the recording knows whether the test passed (ExUnit reports
failures as before). Doctests and other macros' tests count as failed for their artifacts, and a
failure only in an `on_exit` callback counts as passed.

`PlaywrightEx.Test.BrowserPool.shared/1` starts a driver and launches the browser on first use;
every caller with the same options gets the same browser, also with `async: true` (ExUnit runs
those modules concurrently with each other; a module's own tests run one after another). A
context is a fresh browser profile with its own cookies, storage and cache, so tests don't share
state. The drivers stop after the suite.

The browser is shared by default because ExUnit's unit of concurrency is a cheap process, and
its default `max_cases` (twice the schedulers) is much higher than Playwright Test's default
`workers` (half the cores): a browser per concurrent test would be many browsers. Sharing lets
concurrency grow with one browser and a context per test, Playwright's own isolation model. It
suits mixed suites too: browser tests, plain ExUnit tests and tests that use PlaywrightEx
through a library all run in ExUnit's one pool, no worker holds an idle browser, and a test
that needs none never pays for a launch. Per test the work is Playwright Test's, so at the
default parallelism a run takes about as long, with a fraction of the memory and driver CPU.
Wall time differs mostly by scheduling: ExUnit balances whole modules, running a module's tests
one after another, where Playwright Test's `fullyParallel` balances single tests. So many small
`async: true` modules parallelise better than a few big ones.

> #### Firefox: use `exclusive` {: .warning}
>
> Firefox dispatches input for all of a browser's pages in one queue, so a shared Firefox
> browser slows down as concurrent tests grow, until they time out. On Firefox, use
> `BrowserPool.exclusive/1`: one browser per worker, as Playwright Test always does (see
> [Exclusive browsers](#exclusive-browsers)).

Options go in as arguments, merged over the config: `BrowserPool.shared(browser_name: :webkit)`,
`Browser.new_context!(browser, locale: "de-DE")`. `launch_options` are those of
`PlaywrightEx.BrowserType.launch/2`, `context_options` those of
`PlaywrightEx.Browser.new_context/2`. Every context a test creates on a pooled browser starts from
Playwright Test's defaults (`locale: "en-US"`, a 1280x720 viewport, `color_scheme: :light`, ...),
then the config's `context_options`; the options the call gives win. A context created outside a
test (in `setup_all`, or a process of no test), or on a driver you started yourself, gets no
defaults and no recording.

With `base_url`, `goto` and the URL matchers take paths. Actions and navigations wait 30 seconds
by default, and ExUnit's test timeout is 60 seconds; `set_default_timeout/2` makes a stuck action
fail sooner, with a message saying what it waited for. `set_default_navigation_timeout/2` sets
navigations apart.

## Your own case template

To add setup after the page's, use `PlaywrightEx.Case` in your template's `using` and put the
setup after it there; a template's own `setup` runs before the ones its `using` brings in:

```elixir
# test/support/browser_case.ex
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use PlaywrightEx.Case

      setup %{context: context} do
        PlaywrightEx.BrowserContext.set_default_timeout(context, 5_000)
        :ok
      end
    end
  end
end
```

To change a piece, say context options from your own tags, write the template from the pieces.
Its own `setup` runs before those of its `using`, so make `use PlaywrightEx.Test` the first line
of its body: the test is then registered before the template's `setup` creates a context (a
context created before the registration makes it raise, saying so):

```elixir
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate
  use PlaywrightEx.Test

  alias PlaywrightEx.{Browser, BrowserContext}
  alias PlaywrightEx.Test.BrowserPool

  using do
    quote do
      use PlaywrightEx.Test
      alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page}
    end
  end

  # `@tag locale: "de-DE"` on a test.
  setup ctx do
    context = Browser.new_context!(BrowserPool.shared(), Enum.to_list(Map.take(ctx, [:locale])))
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end
```

`use PlaywrightEx.Test` imports only `test`; the rest is called qualified, as Playwright Test's
`test.info()` and `test.step()`: `PlaywrightEx.Test.info/0`, `output_path/1`, `snapshot_path/2`,
`step/3`. So a wrapper library's own `step` doesn't clash. A browser you connect to
(`PlaywrightEx.BrowserType.connect/3`) is yours to manage, without defaults or recording.

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

A soft assertion (Playwright Test's `expect.soft`) doesn't stop the test: it fails the test once
its body has run, and ExUnit reports all of the test's errors:

```elixir
Page.get_by_text(page, "Saved") |> Expect.soft() |> Expect.to_be_visible!()
Page.get_by_role(page, :listitem) |> Expect.soft() |> Expect.to_have_count!(3)
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

## Snapshots

In a test, `Expect.to_have_screenshot!/2` and `Expect.to_match_aria_snapshot!/3` take a `name:`
that resolves next to the test file, as in Playwright Test:

```elixir
Expect.to_have_screenshot!(page, name: "home.png")
# test/sign_up_test.exs-snapshots/home-linux.png (the suffix is the platform)
Expect.to_match_aria_snapshot!(Page.locator(page, "body"))
# test/sign_up_test.exs-snapshots/signs-up-1.aria.yml (no name: the test's name and count)
```

A missing snapshot is written, and fails the test once its body has run, so CI catches a
snapshot nobody committed; ExUnit reports all of the test's errors. `snapshot_dir` and
`snapshot_path_template` (Playwright Test's `snapshotDir`, `snapshotPathTemplate`) move them,
`PlaywrightEx.Test.snapshot_path("home.png", kind: :screenshot)` returns a path, and `update_snapshots` in
`config :playwright_ex, :expect` (`:all`, `:changed`, `:missing`, `:none`) rewrites them. A
failed comparison leaves `-actual`, `-expected`, `-previous` and `-diff` images in the test's dir
under `test-results/`.

## Logging in once

Log in once per module and start each context from the saved cookies and local storage. A
context in `setup_all` belongs to no test, so it gets neither the defaults nor a recording:

```elixir
setup_all do
  context = Browser.new_context!(BrowserPool.shared())
  page = BrowserContext.new_page!(context)
  Page.goto!(page, "http://localhost:4000/login")
  Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
  Page.get_by_label(page, "Password") |> Locator.fill!("secret")
  Page.get_by_role(page, :button, name: "Log in") |> Locator.click!()
  Expect.to_have_url!(page, ~r"/dashboard$")

  storage_state = BrowserContext.storage_state!(context)
  BrowserContext.close!(context)
  %{storage_state: storage_state}
end

setup %{storage_state: storage_state} do
  context = Browser.new_context!(BrowserPool.shared(), storage_state: storage_state)
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

To share the login between modules, `BrowserContext.storage_state!(context, path:
"tmp/auth.json")` also writes it to a file, and `storage_state:` takes that path. An app that keeps
its tokens in IndexedDB (Firebase Authentication) needs `storage_state!(context, indexed_db:
true)`: IndexedDB is not in the state by default. See
[Authentication](https://playwright.dev/python/docs/auth).

## Several users

Each user is a context, and a user on another browser takes it from another `shared/1` call:

```elixir
test "two users edit one document" do
  browser = BrowserPool.shared()
  ada = Browser.new_context!(browser)
  bob = Browser.new_context!(browser)
  eve = Browser.new_context!(BrowserPool.shared(browser_name: :webkit))

  ada_page = BrowserContext.new_page!(ada)
  bob_page = BrowserContext.new_page!(bob)
  eve_page = BrowserContext.new_page!(eve)
  # ...
end
```

All three contexts are recorded into the test's one trace, and each gets its own video.

## Traces, screenshots and videos

Every context a test creates on a pooled browser is recorded, also in a `Task` of the test or a
route handler. Each test writes to a dir of its own under `test-results/`, named after the test
file and name, as Playwright Test's `testInfo.outputDir`, and a short hash of the module (and its
`parameterize:` parameters) that tells same-named tests apart:

```
test-results/sign_up-signs-up-5d41a/trace.zip
test-results/sign_up-signs-up-5d41a/test-failed-1.png
```

A failed test also gets Playwright Test's `error-context.md`: its errors, its source and an aria
snapshot of its page, for you or an agent to read. A failed test that keeps a trace prints how
to open it: `mix playwright_ex.cli show-trace test-results/.../trace.zip`. More in the
[Debugging and CI](debugging-and-ci.md) guide.

`trace`, `screenshot` and `video` are `:off` by default, as in Playwright Test.
`:retain_on_failure` (trace, video) and `:only_on_failure` (screenshot) record every test and
keep the files of failures; a passing test's are dropped at its end. The config sets them for
the suite, and tags for a module, a describe block or a test, as `true`, `false` or a mode:

```elixir
@moduletag video: :retain_on_failure

@tag trace: :on
test "checks out", %{page: page} do
  # ...
end
```

So `trace`, `screenshot` and `video` are reserved tags: a `@tag :screenshot` label turns
screenshots on, and an invalid value raises. As in Playwright Test, each takes options too, with
the mode as `:mode`: `trace: [mode: :on, snapshots: false]`, `screenshot: [mode: :only_on_failure,
full_page: true]`, `video: [mode: :on, size: %{width: 640, height: 480}]`. A tag replaces the
config's value as a whole.

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
`PlaywrightEx.Test.output_path("export.csv")`; they stay when the test passes. A flaky test that
passes on the rerun leaves no trace; for those, `:retain_on_failure`.

The files are written in the test's `on_exit`, which ExUnit runs in reverse order of
registration. An `on_exit` that reads them (to check a `trace.zip`, say) must therefore be
registered before the recording's: in a `setup` above `use PlaywrightEx.Test`. `info/0` raises in
`on_exit`, so give it the path from the test, through an `Agent` for example.

A trace you start yourself (`Tracing.start!(tracing, sources: true)`) on a shared driver also
gets the stacks and sources of concurrent tests, as the driver adds every call's stack to each
trace on the connection. The recording filters them out of its `trace.zip`; for your own traces,
use `BrowserPool.exclusive/1`.

## Steps

`PlaywrightEx.Test.step/3` groups a test's actions under a title, as Playwright Test's `test.step`: the trace
(`test.trace` in `trace.zip`) shows the steps, nested, with each matcher call as a step of its own
and the test's errors. A step returns its body's value and works in a `Task` of the test too:

```elixir
test "signs up in steps", %{page: page} do
  Test.step "fill in the form" do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
  end

  status =
    Test.step("submit", fn ->
      Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
      Page.get_by_role(page, :status)
    end)

  Expect.to_have_text!(status, "Welcome, ada@example.com")
end
```

With `box: true`, an error inside the step is reported where the helper is called, instead of
inside the step, which suits helpers:

```elixir
defp sign_up(page, email) do
  Test.step "sign up", box: true do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!(email)
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
  end
end
```

A step runs in the calling process, so `assert_receive` works in it. It takes no `timeout:`, as a
running body can't be interrupted: the test's timeout bounds it. `step_skip` declares a step
without running it. `Test` is `PlaywrightEx.Test`, which `PlaywrightEx.Case` aliases.

## Route handlers and listeners

Route handlers (`Page.route/3`, `route_web_socket/3` and their WebSocket `on_message` and
`on_close`), event listeners (`Page.on/3`), exposed functions, locator handlers and wait
predicates run in processes of their own, on behalf of the process that registered them: they
get its `$callers`, as a `Task` does. So the Ecto sandbox, Mox and `Req.Test` find the test in
them without an explicit allowance, and matchers and `step` count for the test. An error a route
handler, listener or locator handler raises fails the test at the end of its body, as in
Playwright Test (outside a test, and once the test has ended, it is logged).

## Exclusive browsers

A shared browser suits tests that only use contexts. A module that changes the driver or the
browser for others (registers selectors, sets the test id attribute, closes or traces the
browser) takes one of its own, as Playwright Test's worker gives one:

```elixir
setup_all do
  %{browser: BrowserPool.exclusive()}
end
```

The scope that calls `BrowserPool.exclusive/1` holds the browser: called in `setup_all`, the
module, until it ends; in `setup` or a test (or a `Task` of the test), the test. A test's own
`exclusive()` call is a separate lease from its module's, so a module that holds one in
`setup_all` uses it from the context. The scope's further calls with the same options return the
same browser. At its end, a scope that passed gives the driver back, warm, to the next caller of
its options, and one that failed stops it. To set up each new driver (register selectors, say),
pass `on_start: &MyApp.Selectors.register/1`: the driver's state then holds for every scope that
gets it.

At most `workers` exclusive drivers run at once (config, default half the schedulers, as
Playwright Test's `workers`); the others wait, first come first served, within ExUnit's test
timeout (`setup_all` has none), and a wait of 10 s logs the holders. Shared browsers run outside
that limit. A call with other options takes another driver: prefer `shared`; mark a rare
exclusive module with unusual options `async: false`, so it doesn't wait for a driver of its own
behind the others; raise `workers`; or split the run by options, with tags and `--only` /
`--exclude`.

On Firefox, use `exclusive` for every module (for a whole Firefox run, in your case template's
`setup_all`). For a few Firefox modules in a mixed suite, ExUnit's `group:` works too: modules of
a group never run at once, so they share one Firefox browser one module at a time while the
others run in parallel:

```elixir
use ExUnit.Case, async: true, group: :firefox
use PlaywrightEx.Test

setup do
  context = Browser.new_context!(BrowserPool.shared(browser_name: :firefox))
  %{page: BrowserContext.new_page!(context)}
end
```

## The running test

`PlaywrightEx.Test.info/0` is Playwright Test's `test.info()`: the running test's `test_pid`,
`file`, `test_name` and `output_dir`, in the test's process and in processes with it in
`$callers` (a `Task`, a route handler). A library that owns resources per test (an Ecto sandbox
owner, a session) finds the test from a `Task` with it: `PlaywrightEx.Test.info().test_pid`.

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
