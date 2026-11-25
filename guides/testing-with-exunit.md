# Testing with ExUnit

This library is the client, ExUnit is the test runner. `Playwright.Test` adds what Playwright
Test's worker gives each test: a browser, a fresh context with Playwright Test's defaults, and
traces, screenshots and videos of failures. This guide tests an app that runs somewhere and is
reached through a base URL, whatever it is written in. `Playwright.Test`'s moduledoc is the
reference; the guides show how to use it:

- this one: setup, assertions, steps, handlers and the app under test;
- [Options, devices and projects](test-options.md);
- [Artifacts, retries and workers](test-artifacts.md);
- [Porting Playwright Test specs](porting-playwright-test.md), and what isn't supported.

Snippets alias `Playwright.{Page, Locator, ...}`.

## Setup

Configure the runner in `config/test.exs`:

```elixir
# config/test.exs
config :playwright, :test,
  base_url: "http://localhost:4000",
  trace: :retain_on_failure,
  screenshot: :only_on_failure
```

A test module uses `Playwright.Case`, which gives each test a `context` and a `page`:

```elixir
defmodule MyApp.SignUpTest do
  use Playwright.Case, async: true

  test "signs up", %{page: page} do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!("ada@example.com")
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, :status), "Welcome, ada@example.com")
  end
end
```

`Playwright.Case` is a case template of three pieces, the same as:

```elixir
use ExUnit.Case, async: true
use Playwright.Test
alias Playwright.{Browser, BrowserContext, Expect, Keyboard, Locator, Mouse, Page, Test}
alias Playwright.Test.BrowserPool

setup_all do
  %{browser: BrowserPool.browser(), browser_name: Test.info().use.browser_name}
end

setup %{browser: browser} do
  context = Browser.new_context!(browser)
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

`use Playwright.Test` goes after `use ExUnit.Case`. It registers each test, so the contexts it
creates get Playwright Test's defaults and are recorded, and imports a `test` macro that marks
the end of each test's body, so the recording knows whether the test passed (ExUnit reports
failures as before; see [Registration](Playwright.Test.html#module-registration)).

`Playwright.Test.BrowserPool.browser/1` is Playwright Test's `browser` fixture: called in
`setup_all`, it gives the module a driver and browser of its own while it runs, as Playwright Test
runs a file in one worker. A module that passed hands its browser on, warm, to the next; one that
failed has it replaced ([Workers](test-artifacts.md#workers)). A context is a fresh browser
profile with its own cookies, storage and cache, so tests don't share state. The drivers stop
after the suite, so `test_helper.exs` needs only `ExUnit.start()`.

A module's tests run one after another (ExUnit balances whole modules, where Playwright Test's
`fullyParallel` balances single tests), so many small `async: true` modules parallelise better
than a few big ones: split a big spec into a module per `describe`. Modules that share state in
the app can stay async in one ExUnit group (`use Playwright.Case, async: true, group: :tree`,
Elixir 1.18+): no two tests of a group run at once, while other modules keep running, which beats
`async: false`. `mix test --slowest N` turns on `--trace`, which runs one module at a time, so it
can't time a parallel run.

Options go in as arguments, over the config: `BrowserPool.browser(browser_name: :webkit)`,
`Browser.new_context!(browser, locale: "de-DE")`. Every context a test creates on a pooled
browser starts from Playwright Test's defaults (`locale: "en-US"`, a 1280x720 viewport,
`color_scheme: :light`, ...), then the options of the config, the project, the module, the
describe block and the test ([Options, devices and projects](test-options.md)).

With `base_url`, `goto` and the URL matchers take paths. To set it from the shell, read an env
var in the config: `base_url: System.get_env("BASE_URL", "http://localhost:4000")`.

As in Playwright Test, actions and navigations have no timeout of their own in a test: ExUnit's
test timeout (60 seconds) bounds them; Playwright Test's is 30 seconds, so for the same
behaviour, `ExUnit.start(timeout: 30_000)` in `test_helper.exs`. Just before it, the test's
contexts are closed, so a stuck call fails with "Test timeout of 60000ms exceeded." and its call
log, and the artifacts are kept. To fail sooner, set `action_timeout` and `navigation_timeout` in
the config (milliseconds). `:infinity`, the default, is no limit, and so is `0`, as in every
`timeout:` option ([API conventions](introduction/api-conventions.md#no-timeout)).
`setup_all`'s timeout and the rest: [Timeouts](Playwright.Test.html#module-timeouts).

Each driver call logs `pw:api ...` at `:debug` ([Logging](introduction/getting-started.md#logging)),
so give the test env a logger level (`config :logger, level: :warning`). `ExUnit.start(capture_log:
true)` prints an in-VM app's logs only for failed tests, as Playwright Test hides the
`webServer`'s output.

## Assertions

`Playwright.Expect` has the web-first assertions: they retry until the page matches or the
timeout passes. The bang forms raise `Playwright.ExpectError` with the expected and received
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
config :playwright, :test, expect: [timeout: 10_000]
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
    e in Playwright.ExpectError ->
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
snapshot nobody committed. `update_snapshots` in `config :playwright, :test` (`:all`,
`:changed`, `:missing`, `:none`) rewrites them. A failed comparison leaves `-actual`,
`-expected`, `-previous` and `-diff` images in the test's dir under `test-results/`. Paths and
templates: [Snapshots](Playwright.Test.html#module-snapshots).

## Steps

`Playwright.Test.step/3` groups a test's actions under a title, as Playwright Test's `test.step`:
the trace shows the steps, nested, with each matcher call and each driver call as a step of its
own, and the test's errors. A step returns its body's value and works in a `Task` of the test too:

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

With `box: true`, the step and an error inside it are reported where the helper is called,
which suits helpers, a library's too. The steps inside keep their own locations:

```elixir
defp sign_up(page, email) do
  Test.step "sign up", box: true do
    Page.goto!(page, "/sign-up")
    Page.get_by_label(page, "Email") |> Locator.fill!(email)
    Page.get_by_role(page, :button, name: "Sign up") |> Locator.click!()
  end
end
```

Steps a library's own code makes (its asserts, `Expect` calls, unboxed steps) are located in the
library's file, as upstream's: step locations leave out only the frames of Playwright, ExUnit,
Elixir and OTP.

A step runs in the calling process, so `assert_receive` works in it. It takes no `timeout:`, as a
running body can't be interrupted: the test's timeout bounds it. `step_skip` declares a step
without running it. In `setup_all` a step runs too, unrecorded
([Steps](Playwright.Test.html#module-steps)), so the same helpers serve both. `use Playwright.Test`
imports `test` and replaces ExUnit's `assert` and `refute` with `Playwright.Test.Assertions`' (the
rest of `ExUnit.Assertions` stays imported); the rest of `Playwright.Test` is called qualified (`Test.step`,
`Test.info()`), as Playwright Test's `test.step()`, and a wrapper library's own `step` doesn't
clash.

Each `assert` and `refute` is a step too, as Playwright Test's `expect`: `Expect "assert"`, with
the expression next to it and its right side as `expected`, and a failed one with its error,
at the test's level. They are ExUnit's otherwise, with
the same bindings, messages and stacktraces (a function that ends in one keeps its frame).
Don't `import ExUnit.Assertions` again after `use Playwright.Test`, which makes `assert`
ambiguous. A helper module without `use Playwright.Test` needs `import Playwright.Test.Assertions`
(and, if it imports `ExUnit.Assertions` too, `except: [assert: 1, assert: 2, refute: 1, refute: 2]`
there), else its passed asserts silently leave no step. A library with its own `assert/2` excludes
exactly the arities it defines (`import Playwright.Test.Assertions, except: [assert: 2]`); its own
`refute/2` must also take the `refute(value, expr: ...)` that ExUnit's `refute match?` calls
([Assertions](Playwright.Test.html#module-assertions)).
Assert steps are on by default: `use Playwright.Test, assert_steps: false` keeps ExUnit's own for a
module, and `config :playwright, :test, assert_steps: false` (in `config/test.exs`, as it is
read at compile time, not in `runtime.exs`) for all, which a module's `assert_steps: true`
overrides.

## Route handlers and listeners

Route handlers (`Page.route/3`, `route_web_socket/3` and their WebSocket `on_message` and
`on_close`), event listeners (`Page.on/3`), exposed functions, locator handlers and wait
predicates run in processes of their own, on behalf of the process that registered them: they
get its `$callers`, as a `Task` does. So the Ecto sandbox, Mox and `Req.Test` find the test in
them without an explicit allowance, and matchers and `step` count for the test.

An error a route handler, listener or locator handler raises fails the test and stops it at once,
as Playwright Test's worker does; once the body has ended (in your `on_exit` callbacks) it is only
logged ([Registration](Playwright.Test.html#module-registration) has the details). In a `:dialog`
listener, accept or dismiss the dialog before asserting on it: a dialog left open blocks the page,
so the screenshot and the snapshot of `error-context.md` wait on it until they time out.

An `on_exit` callback is Playwright Test's `afterEach` hook. ExUnit runs it after the test
process has exited and its `start_supervised!/1` children have stopped, but before the test's
contexts close, which is last: it can still use `page` and `context`, and their trace records its
calls. The test's listeners still run in your `on_exit` callbacks, but not as its contexts close.
State linked to the test (an `Agent.start_link/1` of it, a `start_supervised!/1` child) is gone in
`on_exit`, so a listener that uses it there logs "Uncaught in event listener: ... no process":
send to the test process (a late message is dropped with it), or keep the state unlinked
(`Agent.start/1`).

An `on_exit` registered before `use Playwright.Test` (a case template's own `setup`) runs after
the test's contexts have closed. Once the processes that created or closed them have exited,
`Page.is_closed/1` still returns `true`, but other reads (`Page.url/1`, `BrowserContext.pages/1`)
raise `Playwright.TargetClosedError`. Read what you need in the test, or use
`Playwright.Test.info/1`. That raises too once another such callback's process has died,
because ExUnit then runs the remaining callbacks in a new process.

### A check after the test

A fixture teardown that fails the test, such as LiveView's `page` fixture checking for page
errors, is an `on_exit`: an assertion there fails the test, reported by ExUnit as an `on_exit`
failure, and the recording counts it as a failure, so its artifacts are kept. That takes the
`on_exit/1,2` `use Playwright.Test` imports, in a `setup` after the `use` (or in the test), not
`ExUnit.Callbacks.on_exit/2` called qualified; a case template passes the import on only with
the `use` in its `using`, as `Playwright.Case` has it. Its state must outlive the test process. Playwright
Test's option fixtures (`test.extend` with `{ option: true }`, set with `test.use`) are plain
tags or parameter keys of your own: `test.use({ ignoreJSErrors: true })` becomes
`@tag :ignore_js_errors` (or `@describetag`, `@moduletag`, a key of a project's
`Test.parameters/1` map), which the `setup` reads:

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

As upstream's, a `poll` callback that raises fails at once. JS's `(await rows())[0]` is
`undefined` while the list is empty and polling goes on, where `hd([])` raises: read with
`Enum.at(rows, 0)` and leave the check to the assertion.

Events forwarded to the test process arrive when the browser emits them, which can be well after
the action that led to them (a request, a timer). `assert_receive` waits only 100 ms by default,
so give it a timeout, or raise the default with `ExUnit.start(assert_receive_timeout: 5_000)`:

```elixir
test_pid = self()
Page.on(page, :console, &send(test_pid, {:console, ConsoleMessage.text(&1)}))
Page.get_by_role(page, :button, name: "Save") |> Locator.click!()
assert_receive {:console, "saved"}, 5_000
```

To check forwarded events afterwards, as JS collects them into an array, drain the mailbox. An event is
handled before the reply of the call that caused it ([Concurrency](concurrency.md)), so once
that call returned (or a matcher saw its effect), its message is there:

```elixir
defp received(tag) do
  receive do
    {^tag, value} -> [value | received(tag)]
  after
    0 -> []
  end
end

assert received(:console) == ["saved"]
```

See [Events and waiting](events-and-waiting.md) for one-off events (downloads, popups, dialogs).

## Logging in once

Log in once per module and start each context from the saved cookies and local storage. A
context in `setup_all` gets the defaults, `base_url` too, as a test's does, but no recording:

```elixir
setup_all do
  browser = BrowserPool.browser()
  context = Browser.new_context!(browser)
  page = BrowserContext.new_page!(context)
  Page.goto!(page, "/login")
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

A request context created in `setup_all` isn't disposed of by the runner either, as with
upstream's manual `newContext` in `beforeAll`. Dispose of it yourself inside the `setup_all`:
`on_exit(fn -> APIRequestContext.dispose!(request) end)`.

To share the login between modules, `BrowserContext.storage_state!(context, path:
"tmp/auth.json")` also writes it to a file, and `storage_state:` takes that path. An app that keeps
its tokens in IndexedDB (Firebase Authentication) needs `storage_state!(context, indexed_db:
true)`: IndexedDB is not in the state by default. See
[Authentication](https://playwright.dev/python/docs/auth).

To log in once per run, as Playwright Test's setup project or `globalSetup` does, log in from
`test_helper.exs`, which runs before any test, on a driver of its own (one more driver start)
that it stops before the tests start. Outside a test no defaults apply, so give the context its
`base_url`. The config's `storage_state` then starts every test's context from the file:

```elixir
# test/test_helper.exs, after starting the app
{:ok, driver} = Playwright.Supervisor.start_link(name: MyApp.GlobalSetup)
browser = Playwright.instance(MyApp.GlobalSetup) |> Playwright.chromium() |> BrowserType.launch!()
context = Browser.new_context!(browser, base_url: Playwright.Test.config()[:base_url])
page = BrowserContext.new_page!(context)
Page.goto!(page, "/login")
# ... log in, as above
BrowserContext.storage_state!(context, path: "tmp/auth.json")
Supervisor.stop(driver)

ExUnit.start()
```

```elixir
# config/test.exs
config :playwright, :test, base_url: "http://localhost:4000", storage_state: "tmp/auth.json"
```

Any other once-per-run setup (Playwright Test's project `dependencies`) goes there too.

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

## The app under test

`test_helper.exs` starts what a run needs, as Playwright Test's `webServer` does. To start the app
server only when browser tests run (`mix test --only e2e`, also with `--failed`), check the
run's filters, which Mix sets before it loads the helper:

```elixir
# test/test_helper.exs
if :e2e in ExUnit.configuration()[:include], do: MyApp.E2E.start_server!()
ExUnit.start(exclude: [:e2e])
```

When the unit tests' helper doesn't suit a run against the real app (Mox globals, say), give the
browser tests a dir and an env of their own: `test_paths: if(Mix.env() == :e2e, do: ["e2e"],
else: ["test"])` in `mix.exs`, with `e2e/test_helper.exs` and `config/e2e.exs`, run by `MIX_ENV=e2e
mix test`. A dir under `test/` must also be kept out of the other envs with `test_load_filters`
(`test_ignore_filters` only silences the warning). Or make it a Mix project of its own that
reaches the app over HTTP.

An app running as an OS process of its own needs no start in the test VM: `mix test --no-start`
starts no application, so start this library's in `test_helper.exs`
(`Application.ensure_all_started(:playwright)`). A server the tests start themselves inherits
their environment, `MIX_ENV` included when the shell or CI job sets it: pass the child's
explicitly (`env: [{~c"MIX_ENV", ~c"dev"}]` in `Port.open/2`). Like `webServer`, wait in
`test_helper.exs` until its URL answers, and stop it in `ExUnit.after_suite/1` with its process
group (`System.cmd("kill", ["-TERM", "-#{os_pid}"])`, the pid from `Port.info(port, :os_pid)`):
`Port.close/1` closes its pipes but doesn't stop it. Prefer the endpoint in the test VM where you
can: only there does the SQL sandbox below isolate each test's data.

Async modules run at once against one app and one database. Seed data each module owns (names
with `System.unique_integer([:positive])`), or wrap seeding that can't be unique in
`:global.trans/2`. For an Ecto app in the test VM, each test's browser must reach its sandbox:
add `Phoenix.Ecto.SQL.Sandbox` to the endpoint and its LiveView hook (see its docs), and send the
test's metadata as the context's user agent:

```elixir
setup %{browser: browser} do
  owner = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: false)
  metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(MyApp.Repo, owner)
  context = Browser.new_context!(browser, user_agent: Phoenix.Ecto.SQL.Sandbox.encode_metadata(metadata))

  on_exit(fn ->
    BrowserContext.close(context)
    Ecto.Adapters.SQL.Sandbox.stop_owner(owner)
  end)

  %{context: context, page: BrowserContext.new_page!(context)}
end
```

Shared mode (`{:shared, self()}`) would need `async: false`. The `on_exit` closes the context first:
the test's contexts close after your `on_exit` callbacks, by when the owner is gone and the app's
LiveViews log ownership errors.

## Accessibility testing

`@axe-core/playwright` isn't ported: install axe-core with your package manager, evaluate its
script in the page (again after each navigation), as `AxeBuilder` does, and run it:

```elixir
axe_path = "assets/node_modules/axe-core/axe.min.js"

Page.evaluate!(page, File.read!(axe_path))
result = Page.evaluate!(page, "() => axe.run()")
assert result["violations"] == []
```

`axe.run(context, options)` takes what `AxeBuilder`'s `include`, `exclude` and `withTags` set:
`Page.evaluate!(page, "([c, o]) => axe.run(c, o)", [%{include: ["main"]}, %{runOnly: ["wcag2a"]}])`.
Take the axe-core your JS suite's `@axe-core/playwright` resolves, for the same rules. It checks
the main frame only: `AxeBuilder` also runs axe in each iframe and merges the results.
