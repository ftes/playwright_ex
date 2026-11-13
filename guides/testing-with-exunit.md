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

setup_all do
  %{browser: BrowserPool.browser()}
end

setup %{browser: browser} do
  context = Browser.new_context!(browser)
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

`use PlaywrightEx.Test` goes after `use ExUnit.Case`. It registers each test, so the contexts it
creates get Playwright Test's defaults and are recorded, and imports a `test` macro that marks
the end of each test's body, so the recording knows whether the test passed (ExUnit reports
failures as before). Doctests and other macros' tests count as failed for their artifacts, and a
failure only in an `on_exit` callback counts as passed.

`PlaywrightEx.Test.BrowserPool.browser/1` is Playwright Test's `browser` fixture, and the pool
is its worker model: called in `setup_all`, it gives the module a driver and browser of its own
while it runs, as Playwright Test runs a file in one worker. At most `workers` of them run at
once (config, default half the schedulers, as Playwright Test's `workers`); other modules wait
for one, which costs nothing, so ExUnit's `max_cases` can stay as it is. A module that passed
hands its browser on, warm, to the next; one that failed has it replaced. A context is a fresh
browser profile with its own cookies, storage and cache, so tests don't share state. The drivers
stop after the suite.

A module's tests run one after another (ExUnit balances whole modules, where Playwright Test's
`fullyParallel` balances single tests), so many small `async: true` modules parallelise better
than a few big ones.

Options go in as arguments, merged over the config: `BrowserPool.browser(browser_name: :webkit)`,
`Browser.new_context!(browser, locale: "de-DE")`. `launch_options` are those of
`PlaywrightEx.BrowserType.launch/2`, `context_options` those of
`PlaywrightEx.Browser.new_context/2`. Every context a test creates on a pooled browser starts from
Playwright Test's defaults (`locale: "en-US"`, a 1280x720 viewport, `color_scheme: :light`, ...),
then the config's `context_options`; the options the call gives win. A context created outside a
test (in `setup_all`, or a process of no test), or on a driver you started yourself, gets no
defaults and no recording.

With `base_url`, `goto` and the URL matchers take paths. To set it from the shell, read an env
var in the config: `context_options: [base_url: System.get_env("BASE_URL", "http://localhost:4000")]`.
As in Playwright Test, actions and navigations have no timeout of their own in a test: ExUnit's
test timeout (60 seconds) bounds them. Just before it, the test's contexts are closed, so a stuck
call fails with "Test timeout of 60000ms exceeded." and its call log, and the artifacts are kept.
To fail sooner, set `action_timeout` and `navigation_timeout` in the config (milliseconds), or
`set_default_timeout/2` and `set_default_navigation_timeout/2` on a context.

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

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  # `@tag locale: "de-DE"` on a test.
  setup %{browser: browser} = ctx do
    context = Browser.new_context!(browser, Enum.to_list(Map.take(ctx, [:locale])))
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end
```

`use PlaywrightEx.Test` imports only `test`; the rest is called qualified, as Playwright Test's
`test.info()` and `test.step()`: `PlaywrightEx.Test.info/0`, `output_path/1`, `snapshot_path/2`,
`step/3`. So a wrapper library's own `step` doesn't clash.

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
  browser = BrowserPool.browser()
  context = Browser.new_context!(browser)
  page = BrowserContext.new_page!(context)
  Page.goto!(page, "http://localhost:4000/login")
  Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
  Page.get_by_label(page, "Password") |> Locator.fill!("secret")
  Page.get_by_role(page, :button, name: "Log in") |> Locator.click!()
  Expect.to_have_url!(page, ~r"/dashboard$")

  storage_state = BrowserContext.storage_state!(context)
  BrowserContext.close!(context)
  %{browser: browser, storage_state: storage_state}
end

setup %{browser: browser, storage_state: storage_state} do
  context = Browser.new_context!(browser, storage_state: storage_state)
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

To share the login between modules, `BrowserContext.storage_state!(context, path:
"tmp/auth.json")` also writes it to a file, and `storage_state:` takes that path. An app that keeps
its tokens in IndexedDB (Firebase Authentication) needs `storage_state!(context, indexed_db:
true)`: IndexedDB is not in the state by default. See
[Authentication](https://playwright.dev/python/docs/auth).

## Several users

Each user is a context, and a user on another browser takes it from another `browser/1` call,
another worker that the module holds too (over `workers`, so it never waits for itself):

```elixir
test "two users edit one document", %{browser: browser} do
  ada = Browser.new_context!(browser)
  bob = Browser.new_context!(browser)
  eve = Browser.new_context!(BrowserPool.browser(browser_name: :webkit))

  ada_page = BrowserContext.new_page!(ada)
  bob_page = BrowserContext.new_page!(bob)
  eve_page = BrowserContext.new_page!(eve)
  # ...
end
```

All three contexts are recorded into the test's one trace, and each gets its own video.

## Devices

Playwright Test's `test.use({ ...devices['iPhone 13'] })` is a context of the device's options.
`PlaywrightEx.Playwright.devices/1` takes the pooled browser's Playwright and returns each
device's options as a map, which `Browser.new_context!/2` takes as they are or with more:

```elixir
test "on a phone" do
  browser = BrowserPool.browser(browser_name: :webkit)
  iphone = Playwright.devices(BrowserPool.playwright(browser))["iPhone 13"]
  page = BrowserContext.new_page!(Browser.new_context!(browser, Map.put(iphone, :locale, "de-DE")))
  # ...
end
```

The device's options are the call's, so they win over Playwright Test's defaults (its viewport
over the 1280x720 one), and `default_browser_type` (`"webkit"`) says which browser to pass.

### Projects

Playwright Test's `projects`, one run per browser and device, are ExUnit's `parameterize:` over
`browser_name`, with each project's device as above:

```elixir
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate
  use PlaywrightEx.Test

  alias PlaywrightEx.{Browser, BrowserContext, Playwright}
  alias PlaywrightEx.Test.BrowserPool

  @devices %{chromium: "Desktop Chrome", firefox: "Desktop Firefox", webkit: "Desktop Safari"}

  def projects, do: for(name <- [:chromium, :firefox, :webkit], do: %{browser_name: name})

  using do
    quote do
      use PlaywrightEx.Test
      alias PlaywrightEx.{Browser, BrowserContext, Expect, Locator, Page}
    end
  end

  setup_all %{browser_name: name} do
    %{browser: BrowserPool.browser(browser_name: name)}
  end

  setup %{browser: browser, browser_name: name} do
    device = Map.fetch!(Playwright.devices(BrowserPool.playwright(browser)), @devices[name])
    context = Browser.new_context!(browser, device)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end

defmodule MyApp.SignUpTest do
  use MyApp.BrowserCase, async: true, parameterize: MyApp.BrowserCase.projects()
  # ...
end
```

A test sees its project as `browser_name` in the context. ExUnit's filters don't see
`parameterize:` values, so to run one project, have `projects/0` read an env var
(`BROWSERS=chromium mix test`).

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
full_page: true]`, `video: [mode: :on, size: %{width: 640, height: 480}, fps: 10, show: %{test:
%{level: "step"}}]` (`show.test` writes the test's title and steps over the video). A tag replaces the
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
`PlaywrightEx.Test.output_path("export.csv")`; they stay when the test passes.
`PlaywrightEx.Test.attach("export", path: path)` (or `body:`) also shows one in the trace, as
Playwright Test's `testInfo.attach`. A flaky test that
passes on the rerun leaves no trace; for those, `:retain_on_failure`.

The files are written in the test's `on_exit`, which ExUnit runs in reverse order of
registration. An `on_exit` that reads them (to check a `trace.zip`, say) must therefore be
registered before the recording's: in a `setup` above `use PlaywrightEx.Test`. `info/0` raises in
`on_exit`, which runs in a process of its own; `PlaywrightEx.Test.info(test_pid)` works there, with
the test's result as Playwright Test's `testInfo` has it in teardown (`status`, `errors`,
`duration`):

```elixir
setup %{test_pid: test_pid} do
  on_exit(fn ->
    %{status: status, output_dir: dir} = PlaywrightEx.Test.info(test_pid)
    if status != :passed, do: MyApp.CI.upload(Path.join(dir, "trace.zip"))
  end)
end

use PlaywrightEx.Test
```

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

The test's contexts close last in its `on_exit`: after your `on_exit` callbacks, as Playwright
Test runs `afterEach` hooks before the `context` fixture's teardown, and after the test process
has exited. The test's listeners (registered in its process, its `setup` or a `Task`) still run
in your `on_exit` callbacks, but not as its contexts close. State linked to the test (an
`Agent.start_link/1` of it, a `start_supervised!/1` child) is gone in `on_exit`, so a listener
that uses it there logs "Uncaught in event listener: ... no process": send to the test process
(a late message is dropped with it), or keep the state unlinked (`Agent.start/1`).

### A check after the test

A fixture teardown that fails the test, such as LiveView's `page` fixture checking for page
errors, is an `on_exit`: an assertion there fails the test, reported by ExUnit as an `on_exit`
failure. Its state must outlive the test process. An option fixture (`test.use({ ignoreJSErrors:
true })`) becomes a tag the `setup` reads (`@tag`, `@describetag` or `@moduletag`):

```elixir
setup %{page: page} = ctx do
  {:ok, errors} = Agent.start(fn -> [] end)
  Page.on(page, :page_error, fn error -> Agent.update(errors, &(&1 ++ [error])) end)

  on_exit(fn ->
    page_errors = Agent.get(errors, & &1)
    Agent.stop(errors)
    if !ctx[:ignore_js_errors], do: assert(page_errors == [], "unhandled page errors")
  end)
end
```

The recording counts such a failure as a pass (see `PlaywrightEx.Test`).

## Workers

A worker, Playwright Test's, is a driver and its browser, held by the module (`setup_all`) or
test that calls `BrowserPool.browser/1`: reused warm after a passing scope, replaced after a
failing one (`PlaywrightEx.Test.BrowserPool` has the rules). That needs the tests' results, so
`use PlaywrightEx.Test`: without it a module counts as passed. To set up each new driver
(register selectors, say), pass `on_start: &MyApp.Selectors.register/1`: the driver's state then
holds for every scope that gets it.

The test id attribute of `get_by_test_id` is global to the VM, as Playwright's is to a worker
process, so a module that sets it changes it for every test running at once. Set it for the
suite, as Playwright Test's `testIdAttribute`; each pooled driver gets it:

```elixir
# config/test.exs
config :playwright_ex, :test, test_id_attribute: "data-pw"
```

At most `workers` drivers run at once; the others wait, first come first served, inside
`BrowserPool.browser/1`: in `setup_all` with no timeout, in `setup` or a test within ExUnit's
test timeout. A worker is a driver and one browser of one
set of options, as Playwright Test's worker runs one project: a call with other options (another
`browser_name`, `launch_options`, `driver` or `on_start`) takes another worker, which may
restart an idle one of other options. ExUnit runs modules in random order, so in a run that
mixes options each switch restarts a worker (a driver start, about 110 ms, plus the browser's
launch). Run one configuration per invocation, as Playwright Test's projects effectively do: tag
each module with its configuration (`@moduletag browser: :firefox`) and run
`mix test --only browser:firefox`, or give each CI job one. A rare module with unusual options
can be `async: false`, so it doesn't wait behind the others.

The defaults: `workers` half the schedulers (Playwright Test's default, half the cores), and
ExUnit's `max_cases` unchanged, twice the schedulers. So about four times as many modules run as
Playwright Test's workers: those past `workers` wait inside `browser/1` at no cost, and modules
that never call it are unaffected. `workers` stays below `max_cases` because each running
browser test keeps a browser, its renderer and the driver busy: on an 18-core Mac, LiveView's
e2e suite at `max_cases` 36 took 64.6 s at 15.0 GB peak memory with 9 workers, and 80.2 s at
38.7 GB with 36.

A suite whose tests mostly wait on the app needs more: raise `workers` toward the core count. An
app's full e2e suite on 18 cores at `max_cases` 18 took 93.8 s at 6.5 GB with 16 workers,
against 113.5 s at 6.1 GB with the default 9. Keep `max_cases` at about the core count for
browser suites: past it the app's CPU saturates. At `max_cases` 36 the same suite gained nothing
(100.9 to 102.7 s) and hit 4 s action timeouts.

## Debugging one test

To watch one module run headed, slowed down, give it a browser with those launch options:

```elixir
@moduletag :debug

setup_all do
  %{browser: BrowserPool.browser(launch_options: [headless: false, slow_mo: 500])}
end

setup %{browser: browser} do
  context = Browser.new_context!(browser)
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

and run it alone: `mix test test/my_app/sign_up_test.exs`, or `mix test --only debug`. The
`launch_options` merge over the config's one key at a time, so its other launch options stay.

To step through a test with `Page.pause/1`, tag it `@tag timeout: :infinity` (or run `mix test
--trace`): otherwise ExUnit's timeout ends the test mid-pause, closing its contexts. The same goes
for the Inspector: `PWDEBUG=1 mix test --trace test/my_app/sign_up_test.exs:12` (see the
[debugging guide](debugging-and-ci.md#watching-it-run)).

## Remote browsers

To run the browsers elsewhere (Playwright's Docker image, a grid), pass `connect_options`,
Playwright Test's `connectOptions`: the pool then connects to a Playwright server instead of
launching. It takes `ws_endpoint` and the options of `PlaywrightEx.BrowserType.connect/3`:

```elixir
# config/test.exs
config :playwright_ex, :test,
  connect_options: [ws_endpoint: "ws://localhost:3000/", expose_network: "<loopback>"]
```

Start the server as in [Remote browsers](debugging-and-ci.md#remote-browsers). The local driver
still runs `on_start`, and contexts on the connected browser get Playwright Test's defaults and
are recorded, as on a launched one. `launch_options` go to the server in the
`x-playwright-launch-options` header, as Playwright Test sends them; the server applies those
it allows (`headless`, `channel`, `slow_mo`, ...). A connected browser and a launched one are
different browsers, also of one `browser_name`, and a lost connection is made again by the next
call.

Each driver connects once, and the server launches a browser per connection, so each worker has
a browser of its own, as each Playwright Test worker does.

A call's `connect_options` win over the config's, and `connect_options: nil` launches. To switch
a suite from the shell, read an env var in the config:

```elixir
# config/test.exs
config :playwright_ex, :test,
  connect_options: if(url = System.get_env("PW_TEST_CONNECT_WS_ENDPOINT"), do: [ws_endpoint: url])
```

`PW_TEST_CONNECT_WS_ENDPOINT=ws://localhost:3000/ mix test` then runs on remote browsers.

The remote browser must reach your app: set `base_url` to a host the container resolves
(`http://host.docker.internal:4000` on Docker Desktop), or pass `expose_network: "<loopback>"`
so the server tunnels `localhost` to your machine.

## The running test

`PlaywrightEx.Test.info/0` is Playwright Test's `test.info()`: the running test's `test_pid`,
`file`, `test_name`, `output_dir` and `timeout` (ExUnit's, `:infinity` for none), in the test's
process and in processes with it in `$callers` (a `Task`, a route handler). A library that owns resources per test (an Ecto sandbox
owner, a session) finds the test from a `Task` with it: `PlaywrightEx.Test.info().test_pid`.

## Polling and waiting

When the state shows in the page, assert on the page: `Expect.*` retries. For state elsewhere (an
email, a background job, a record behind an API), retry the assertion with `Expect.to_pass!/2`
(`expect(fn).toPass()`), or poll a value with `Expect.poll!/3` (`expect.poll(fn).toBe(x)`), whose
matcher is an ExUnit assertion:

```elixir
Expect.to_pass!(fn ->
  response = APIRequestContext.get!(BrowserContext.request(context), "/api/exports/1")
  assert APIResponse.json!(response)["status"] == "done"
end)

Expect.poll!(fn -> Repo.aggregate(Export, :count) end, &assert(&1 == 1), timeout: 10_000)
```

As upstream's, `to_pass` retries until the test's timeout (`timeout:` for less) and `poll` for
the matchers' `timeout`, both at `[100, 250, 500, 1000]` ms intervals (`intervals:`). The callback
runs in the test process, so `self()` and its mailbox are the test's; a step or a soft receiver
(`fun |> Expect.soft() |> Expect.to_pass!()`) works as for any matcher.

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

## Porting Playwright Test specs

Most of a spec ports call for call. What differs:

- JS `null` is `:null` (`undefined` is `nil`), and objects from `evaluate` are maps with string
  keys (`result["entry"]["foo"]`).
- A JS regex literal PCRE rejects (`/\patched/`: `\p` is `p` in JS without `u`) needs
  `PlaywrightEx.RegExp.new/1`, which sends the JS source as it is.
- `test.skip(condition)` at runtime has no ExUnit equivalent: ExUnit can't skip a running test,
  and its filters don't see `parameterize:` values. Use a tag known before the run
  (`@tag skip: ...`, `--exclude`), or an `if` around the body (reported as passed).
- `describe` blocks don't nest, and their names must be unique in a module: the outer one becomes
  the module (its `beforeEach` a module `setup`), and a `describe` repeated in a loop becomes one
  `describe` with the loop inside.
- `elementHandle.evaluate(...)` is `JSHandle.evaluate!(element_handle, ...)`: an `ElementHandle`
  takes the `JSHandle` functions.
- Asymmetric matchers (`expect.objectContaining`, `expect.any(String)`) become patterns:
  `assert [%{"id" => id} | _] = list`, then `assert is_binary(id)`.
- Module-level `let` state reset in `beforeEach` becomes per-test state, returned from `setup` or
  kept in an `Agent` (unlinked when an `on_exit` reads it, see "A check after the test").
- `expect(fn).toPass()` is `Expect.to_pass!/2`, `expect.poll(fn).toBe(x)` is
  `Expect.poll!(fn, &assert(&1 == x))`, and a call started now and awaited later
  (`const p = locator.evaluate(...)`) is `PlaywrightEx.Promise.async/1` (see
  [Concurrency](concurrency.md)).
