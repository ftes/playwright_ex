# Testing with ExUnit

This library is the client, ExUnit is the test runner. `Playwright.Test` adds what Playwright
Test's worker gives each test: a browser, a fresh context with Playwright Test's defaults, and
traces, screenshots and videos of failures. This guide tests an app that runs somewhere and is
reached through a base URL, whatever it is written in. Snippets alias
`Playwright.{Page, Locator, ...}`.

## Setup

Configure the runner in `config/test.exs`:

```elixir
# config/test.exs
config :playwright, :test,
  context_options: [base_url: "http://localhost:4000"],
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
  %{browser: BrowserPool.browser()}
end

setup %{browser: browser} do
  context = Browser.new_context!(browser)
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

`use Playwright.Test` goes after `use ExUnit.Case`. It registers each test, so the contexts it
creates get Playwright Test's defaults and are recorded, and imports a `test` macro that marks
the end of each test's body, so the recording knows whether the test passed (ExUnit reports
failures as before). Doctests and other macros' tests count as failed for their artifacts, and a
failure only in an `on_exit` callback counts as passed.

`Playwright.Test.BrowserPool.browser/1` is Playwright Test's `browser` fixture, and the pool
is its worker model: called in `setup_all`, it gives the module a driver and browser of its own
while it runs, as Playwright Test runs a file in one worker. At most `workers` of them run at
once (config, default half the schedulers, as Playwright Test's `workers`); other modules wait
for one, which costs nothing, so ExUnit's `max_cases` can stay as it is. A module that passed
hands its browser on, warm, to the next; one that failed has it replaced. A context is a fresh
browser profile with its own cookies, storage and cache, so tests don't share state. The drivers
stop after the suite.

A module's tests run one after another (ExUnit balances whole modules, where Playwright Test's
`fullyParallel` balances single tests), so many small `async: true` modules parallelise better
than a few big ones: split a big spec into a module per `describe`. Modules that share state in
the app can stay async in one ExUnit group (`use Playwright.Case, async: true, group: :tree`,
Elixir 1.18+): no two tests of a group run at once, while other modules keep running, which beats
`async: false`. `mix test --slowest N` turns on `--trace`, which runs one module at a time, so it
can't time a parallel run.

Options go in as arguments, merged over the config: `BrowserPool.browser(browser_name: :webkit)`,
`Browser.new_context!(browser, locale: "de-DE")`. `launch_options` are those of
`Playwright.BrowserType.launch/2`, `context_options` those of
`Playwright.Browser.new_context/2`. Every context a test creates on a pooled browser starts from
Playwright Test's defaults (`locale: "en-US"`, a 1280x720 viewport, `color_scheme: :light`, ...),
then the config's `context_options`, then its project's, its module's, its describe block's and
its own, each over the one before per option:

| Playwright Test | Here |
|---|---|
| `use: { ... }` in the config | `config :playwright, :test, context_options: [...]` |
| a project's `use` | `parameterize: [Playwright.Test.parameters(context_options: [...])]`, see "Projects" |
| `test.use({ ... })` at a file's top | `use Playwright.Case, context_options: [locale: "de-DE"]` |
| `test.use({ ... })` in a `test.describe` | `@describetag Test.use(context_options: [...])` |
| (a describe around one test) | `@tag Test.use(context_options: [...])` |

The options the call gives win. The config's, the project's and the module's options reach
every context the module creates, `setup_all`'s included (`goto("/")` works there with
`base_url`); a describe's and a test's reach that test's contexts, as ExUnit runs `setup_all`
without them. They are keyword lists known at compile time, not functions, and "Devices" has an
example of each level. The other options layer the same way, where they can be set:

| Option | Config | Project (`Test.parameters/1`) | Module (`use`) | Describe, test (`Test.use/1`) |
|---|---|---|---|---|
| `context_options`, `action_timeout`, `navigation_timeout` | yes | yes | yes | yes |
| `trace`, `screenshot`, `video` | yes | yes | yes | yes (an addition: worker-scoped in Playwright Test, which rejects them in a describe) |
| `browser_name`, `launch_options`, `connect_options` | yes | yes | yes | no: the worker's, as in Playwright Test, where they force a new worker |
| a device's `default_browser_type` (in `context_options`) | picks the browser | picks the browser | picks the browser | ignored (a deviation: Playwright Test rejects it there; the device's emulation applies on the module's browser) |
| `test_id_attribute` | yes | no | no | no (a deviation: the value is global to the VM, which concurrent tests share) |
| `output_dir`, `preserve_output`, `workers`, `snapshot_dir`, `snapshot_path_template`, `driver`, `on_start` | yes | no | no | no |

The module's `browser_name`, `launch_options` (per key) and `connect_options` are the defaults
of its `BrowserPool.browser/1` calls, so of `Playwright.Case`'s `browser`: a module or a
project with `launch_options: [channel: "chrome"]` gets a worker of its own. A
process the test or `setup_all` starts counts only
with `$callers`: a `Task`, and route handlers and listeners registered there, have them (see
[Route handlers and listeners](#route-handlers-and-listeners)); a `spawn`, a `GenServer` or
`start_supervised` doesn't. A long-lived process or handler of `setup_all`'s with them gives the
module's defaults to every context it creates later, in a test too, but no test records them
(see "Not ported yet" below). A context created elsewhere (an `on_exit` callback, a process of no test), or on a
driver you started yourself, gets no defaults and no recording.

With `base_url`, `goto` and the URL matchers take paths. To set it from the shell, read an env
var in the config: `context_options: [base_url: System.get_env("BASE_URL", "http://localhost:4000")]`.
As in Playwright Test, actions and navigations have no timeout of their own in a test: ExUnit's
test timeout (60 seconds) bounds them; Playwright Test's is 30 seconds, so for the same
behaviour, `ExUnit.start(timeout: 30_000)` in `test_helper.exs`. Just before it, the test's
contexts are closed, so a stuck call fails with "Test timeout of 60000ms exceeded." (the timeout's
milliseconds) and its call log, and the artifacts are kept. To fail sooner, set `action_timeout` and `navigation_timeout` in the config (milliseconds), or
`set_default_timeout/2` and `set_default_navigation_timeout/2` on a context. `:infinity`, the
default, is no limit, and so is `0`, in the config as in every `timeout:` option: as in
Playwright, `0` never means "fail at once" ([API conventions](api-conventions.md)). A context of
`setup_all` gets the same `action_timeout` and `navigation_timeout` (no limit by default, as
Playwright Test's `beforeAll` contexts). The module's timeout (`@moduletag timeout:`, else
ExUnit's) bounds its `setup_all` callbacks, as Playwright Test bounds each `beforeAll` hook: past
it, the `setup_all` fails with `"setup_all" hook timeout of 60000ms exceeded.`, but without the
call log, as its contexts aren't closed before. Its pooled browsers reset at the module's end,
as after a failed test, which closes them.

Each driver call logs `pw:api ...` at `:debug` ([Logging](getting-started.md#logging)), so give
the test env a logger level (`config :logger, level: :warning`). `ExUnit.start(capture_log:
true)` prints an in-VM app's logs only for failed tests, as Playwright Test hides the
`webServer`'s output.

## Your own case template

To add setup after the page's, use `Playwright.Case` in your template's `using` and put the
setup after it there; a template's own `setup` runs before the ones its `using` brings in:

```elixir
# test/support/browser_case.ex
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Playwright.Case

      setup %{context: context} do
        Playwright.BrowserContext.set_default_timeout(context, 5_000)
        :ok
      end
    end
  end
end
```

To change a piece, say another browser, write the template from the pieces (with only `use Playwright.Case`'s browser
and options to change, see "Devices" and "Projects" first).
Its own `setup` runs before those of its `using`, so make `use Playwright.Test` the first line
of its body: the test is then registered before the template's `setup` creates a context (a
context created before the registration makes it raise, saying so):

```elixir
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate
  use Playwright.Test

  alias Playwright.{Browser, BrowserContext}
  alias Playwright.Test.BrowserPool

  using do
    quote do
      use Playwright.Test
      alias Playwright.{Browser, BrowserContext, Expect, Locator, Page, Test}
    end
  end

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  # `@tag Test.use(context_options: [locale: "de-DE"])` on a test sets its options.
  setup %{browser: browser} do
    context = Browser.new_context!(browser)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end
```

`use Playwright.Test` imports only `test`; the rest is called qualified, as Playwright Test's
`test.info()` and `test.step()`: `Playwright.Test.info/0`, `output_path/1`, `snapshot_path/2`,
`step/3`. So a wrapper library's own `step` doesn't clash. It also requires `Playwright.Test`, for
the `step` macro; the alias makes it `Test.step`, as in `Playwright.Case`.

An `on_exit` callback is Playwright Test's `afterEach` hook. ExUnit runs it after the test process
has exited and its `start_supervised!/1` children have stopped, but before the test's contexts
close, which is last: it can still use `page` and `context`, and their trace records its calls.
A context it closes itself is recorded as one closed in the test (its trace and screenshots are
taken at the close), and the files are written at the very end, with the test's result.

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
config :playwright, :expect, timeout: 10_000
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
snapshot nobody committed; ExUnit reports all of the test's errors. `snapshot_dir` and
`snapshot_path_template` (Playwright Test's `snapshotDir`, `snapshotPathTemplate`) move them,
`Playwright.Test.snapshot_path("home.png", kind: :screenshot)` returns a path, and `update_snapshots` in
`config :playwright, :expect` (`:all`, `:changed`, `:missing`, `:none`) rewrites them. A
failed comparison leaves `-actual`, `-expected`, `-previous` and `-diff` images in the test's dir
under `test-results/`.

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
`base_url`. The config's `context_options` then start every test's context from the file:

```elixir
# test/test_helper.exs, after starting the app
{:ok, driver} = Playwright.Supervisor.start_link(name: MyApp.GlobalSetup)
browser = Playwright.instance(MyApp.GlobalSetup) |> Playwright.chromium() |> BrowserType.launch!()
context = Browser.new_context!(browser, base_url: Playwright.Test.config().context_options[:base_url])
page = BrowserContext.new_page!(context)
Page.goto!(page, "/login")
# ... log in, as above
BrowserContext.storage_state!(context, path: "tmp/auth.json")
Supervisor.stop(driver)

ExUnit.start()
```

```elixir
# config/test.exs
config :playwright, :test,
  context_options: [base_url: "http://localhost:4000", storage_state: "tmp/auth.json"]
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

## Devices

Playwright Test's `devices['iPhone 13']` is `Playwright.device("iPhone 13")`: the device's
context options as a map, static data of the pinned Playwright version, so it needs no driver
and works at compile time. An unknown name raises, naming the closest;
`Playwright.devices/0` is the map of all of them, and its docs list the names.
`Browser.new_context!/2` takes a device as it is or with more:

```elixir
test "on a phone" do
  browser = BrowserPool.browser(browser_name: :webkit)
  iphone = Playwright.device("iPhone 13")
  page = BrowserContext.new_page!(Browser.new_context!(browser, Map.put(iphone, :locale, "de-DE")))
  # ...
end
```

The device's options are the call's, so they win over Playwright Test's defaults (its viewport
over the 1280x720 one), and its `default_browser_type` (`"webkit"`) names its browser, which
`new_context` ignores.

For a module, Playwright Test's `test.use({ ...devices['iPhone 13'] })` at a file's top, give
the device to the `use`:

```elixir
defmodule MyApp.PhoneTest do
  use Playwright.Case, async: true, context_options: Playwright.device("iPhone 13")

  test "on a phone", %{page: page} do
    # ...
  end
end
```

As in Playwright Test, the device also picks the browser: without a `browser_name` in the
module's `use`, its project or the config, `BrowserPool.browser/1` (so `Playwright.Case`'s
`browser`) launches the device's `default_browser_type`, WebKit here. A `browser_name` set in
any of those wins (`use Playwright.Case, browser_name: :chromium, context_options: ...`, or
`config :playwright, :test, browser_name: :chromium`).

For a describe block, Playwright Test's `test.use` in a `test.describe`, tag it with
`Playwright.Test.use/1`, which takes the `use` options `context_options`, `action_timeout`,
`navigation_timeout`, `trace`, `screenshot` and `video`:

```elixir
describe "in Berlin" do
  @describetag Test.use(context_options: [timezone_id: "Europe/Berlin", locale: "de-DE"])

  test "shows local time", %{page: page} do
    # ...
  end
end
```

For one test, `@tag` it. Playwright Test has no `test.use` for a single test, and nests a
describe around it instead; ExUnit's describe blocks can't nest:

```elixir
@tag Test.use(context_options: [color_scheme: :dark], trace: :on)
test "is readable in the dark", %{page: page} do
  # ...
end
```

To run one test per device, generate them, as Playwright Test's loop over `test.describe`
blocks with a `test.use`:

```elixir
for name <- ["iPhone 13", "Pixel 7"] do
  @tag Test.use(context_options: Playwright.device(name))
  test "the menu collapses on #{name}", %{page: page} do
    # ...
  end
end
```

A describe's and a test's options are of the test's contexts, on the module's browser: the
browser is the worker's, as in Playwright Test, where a describe with another one starts a new
worker. So `browser_name` is an option of the module's `use` and of a project, and
`Test.use(browser_name: _)` raises; nor does a tag's device switch the browser. Only what
`Test.use/1` returns is read: a tag named as an option (`@tag trace: :on`) sets nothing.

For the whole suite, the device goes in the config's `context_options`. `config/config.exs` and
`config/test.exs` are evaluated before the dependencies are compiled, so `Playwright.device/1`
can't be called there: write the options out, or set them in `config/runtime.exs`, which runs
after the compilation (the runner reads the config at run time):

```elixir
# config/runtime.exs
if config_env() == :test do
  config :playwright, :test, context_options: Playwright.device("iPhone 13")
end
```

### Projects

Playwright Test's `projects: [{ use: { ...devices['Desktop Chrome'] } }, ...]`, one run per
browser and device, are ExUnit's `parameterize:` with a `Playwright.Test.parameters/1` map per
project. It takes `Test.use/1`'s options and the worker's (`browser_name`, `launch_options`,
`connect_options`):

```elixir
defmodule MyApp.Projects do
  # `PROJECTS="Desktop Firefox" mix test` runs one.
  def all do
    names = String.split(System.get_env("PROJECTS", "Desktop Chrome,Desktop Firefox,Desktop Safari"), ",")
    for name <- names, do: Playwright.Test.parameters(context_options: Playwright.device(name))
  end
end

defmodule MyApp.SignUpTest do
  use Playwright.Case, async: true, parameterize: MyApp.Projects.all()

  test "signs up", %{page: page} do
    # ...
  end
end
```

The project's options are over the config's and under the module's `use`, for every context of
the module's run, `setup_all`'s included, and its device picks the browser as above: Chromium,
Firefox and WebKit here (not with a `browser_name` in the config, which wins over a device:
give the projects one, `Test.parameters(browser_name: :firefox, context_options: ...)`). A
module adds its own options over the project's (`use Playwright.Case, parameterize:
MyApp.Projects.all(), context_options: [locale: "de-DE"]`), and parameters of your own go next
to them: `Map.put(Test.parameters(...), :role, :admin)`. They also name the project in
`Playwright.Test.GitHubFormatter`'s report, as its `browser_name` does (`[firefox]`). A test reads its browser from the
`browser`: `Playwright.BrowserType.name(Browser.browser_type(browser))`. ExUnit's filters don't see
`parameterize:` values, so to run one project, read an env var where the list is built, as
above.

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
to open it after the run: `mix playwright.cli show-trace test-results/.../trace.zip`. More in the
[Debugging and CI](debugging-and-ci.md) guide.

`trace`, `screenshot` and `video` are `:off` by default, as in Playwright Test.
`:retain_on_failure` (trace, video) and `:only_on_failure` (screenshot) record every test and
keep the files of failures; a passing test's are dropped at its end. The config sets them for
the suite, `use Playwright.Test`'s options for a module (Playwright Test's file-level
`test.use({ trace: 'on' })`), and `Playwright.Test.use/1` in a tag for a describe block or a
test (in a `parameterize:` map, `Playwright.Test.parameters/1`, for a project), as `true`,
`false` or a mode, each over the one before:

```elixir
use Playwright.Case, trace: :retain_on_failure, video: :retain_on_failure

@tag Test.use(trace: :on)
test "checks out", %{page: page} do
  # ...
end
```

Tags named `trace`, `screenshot` or `video` set nothing (they did before 1.65.0-rc.2): only
`Test.use/1`'s keys are read, so a `@tag :screenshot` label is yours. As in
Playwright Test, each takes options too, with the mode as `:mode`: `trace: [mode: :on,
snapshots: false]`, `screenshot: [mode: :only_on_failure, full_page: true]`, `video: [mode: :on,
size: %{width: 640, height: 480}, fps: 10, show: %{test: %{level: "step"}}]` (`show.test` writes
the test's title and steps over the video). Each replaces the value under it as a whole; an
unknown `use` option or an invalid value fails the module's compilation.

`use Playwright.Case, async: true, trace: :on` takes them next to ExUnit's options. A module's
`use`s merge per key, the later winning, and ExUnit.Case's keys are ignored, so a template
forwards its options as is, after its own defaults. They go in `using`: a `use` in the
template's body takes none. Options of the template's own are unknown to `use
Playwright.Test` and raise: pop them before forwarding the rest.

```elixir
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate
  use Playwright.Test

  using opts do
    {sandbox, opts} = Keyword.pop(opts, :sandbox, true)

    quote do
      use Playwright.Test, screenshot: :only_on_failure
      use Playwright.Test, unquote(opts)
      @moduletag sandbox: unquote(sandbox)
    end
  end

  # ...
end

defmodule MyApp.CheckoutTest do
  use MyApp.BrowserCase, async: true, trace: :on, sandbox: false
end
```

Tracing slows every test. Playwright Test's answer is to trace only the retry of a failure
(`on-first-retry`). ExUnit has no retries in a run, but `mix test --failed` is one: under it a
test is Playwright Test's retry (`Playwright.Test.info().retry` is 1, then 2 on the next
`--failed`), and the retry modes go by it. So trace only the rerun:

```elixir
# config/test.exs
config :playwright, :test, trace: :on_first_retry
```

and rerun the failures in CI, only on exit status 2 (tests failed; a crash or a missed
`--cover` threshold isn't retried, and an empty `--failed` run would pass):

```sh
mix test || { [ $? -eq 2 ] && mix test --failed; }
```

The other retry modes are Playwright Test's too: `:on_all_retries` traces every rerun,
`:retain_on_first_failure` the first run's failures, `:retain_on_failure_and_retries` both;
`video` takes them as well, and `screenshot` has `:on_first_failure`.

Passing runs pay nothing for it, and the first run's files stay. A test's dir is emptied before
it runs, so a test that passes now keeps no `error-context.md` of an earlier failure. A rerun
writes to `<dir>-retry1`, next to the first run's dir:

```
test-results/sign_up-signs-up-5d41a/error-context.md
test-results/sign_up-signs-up-5d41a-retry1/trace.zip
```

A run without `--failed` deletes the test's `-retryN` dirs too. The dirs of tests that don't
run stay, where Playwright Test empties `test-results/` at the start of a run. Files of your own go in the test's dir with
`Playwright.Test.output_path("export.csv")`; they stay when the test passes.
`Playwright.Test.attach("export", path: path)` (or `body:`) also shows one in the trace, as
Playwright Test's `testInfo.attach`. Config `preserve_output` is Playwright Test's
`preserveOutput`: `:failures_only` deletes a passing test's dir at its end, `:never` every
test's. The retry is counted from the `-retryN` dirs on disk, so under `:never` each `--failed`
run is retry 1 again. A flaky test that passes on the rerun keeps that passing run's trace; for the failure's
own too, `:retain_on_failure_and_retries`.

The files are written in the test's `on_exit`, which ExUnit runs in reverse order of
registration. An `on_exit` that reads them (to check a `trace.zip`, say) must therefore be
registered before the recording's: in a `setup` above `use Playwright.Test`. `info/0` raises in
`on_exit`, which runs in a process of its own; `Playwright.Test.info(test_pid)` works there, with
the test's result as Playwright Test's `testInfo` has it in teardown (`status`, `errors`,
`duration`):

```elixir
setup %{test_pid: test_pid} do
  on_exit(fn ->
    %{status: status, output_dir: dir} = Playwright.Test.info(test_pid)
    if status != :passed, do: MyApp.CI.upload(Path.join(dir, "trace.zip"))
  end)
end

use Playwright.Test
```

## Steps

`Playwright.Test.step/3` groups a test's actions under a title, as Playwright Test's `test.step`: the trace
(`test.trace` in `trace.zip`) shows the steps, nested, with each matcher call and each driver call
as a step of its own, and the test's errors. A step returns its body's value and works in a `Task` of the test too:

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
without running it. `Test` is `Playwright.Test`, which `Playwright.Case` aliases.

## Route handlers and listeners

Route handlers (`Page.route/3`, `route_web_socket/3` and their WebSocket `on_message` and
`on_close`), event listeners (`Page.on/3`), exposed functions, locator handlers and wait
predicates run in processes of their own, on behalf of the process that registered them: they
get its `$callers`, as a `Task` does. So the Ecto sandbox, Mox and `Req.Test` find the test in
them without an explicit allowance, and matchers and `step` count for the test. An error a route
handler, listener or locator handler raises fails the test and stops it at once, as Playwright
Test's worker does: the test's process exits with that error, and later such errors are dropped.
Soft errors recorded before it are reported with it. A test that traps exits isn't stopped:
ExUnit may report it passed, while the error is in `error-context.md` and
`Playwright.Test.info/1`. A test defined with `ExUnit.Case.test` in place of the `test` macro
isn't a Playwright test: its listener errors are only logged.

Two points differ from Playwright Test. Once the test's body has ended (in your `on_exit`
callbacks), and outside a test, such an error is only logged; Playwright Test still fails the
test during its `afterEach` hooks and teardown. And a test stopped this way gets its failure
screenshots at teardown, as its contexts close, so after your `on_exit` callbacks; Playwright
Test takes them before the `afterEach` hooks, as for any other failure. In a `:dialog` listener,
accept or dismiss the dialog before asserting on it: a dialog left open blocks the page, so the
screenshot and the snapshot of `error-context.md` wait on it until they time out.

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

The recording counts such a failure as a pass (see `Playwright.Test`).

## Workers

A worker, Playwright Test's, is a driver and its browser, held by the module (`setup_all`) or
test that calls `BrowserPool.browser/1`: reused warm after a passing scope, replaced after a
failing one (`Playwright.Test.BrowserPool` has the rules). That needs the tests' results, so
`use Playwright.Test`: without it a module counts as passed. To set up each new driver
(register selectors, say), pass `on_start: &MyApp.Selectors.register/1`: the driver's state then
holds for every scope that gets it.

The test id attribute of `get_by_test_id` is global to the VM, as Playwright's is to a worker
process, so a module that sets it changes it for every test running at once. Set it for the
suite, as Playwright Test's `testIdAttribute`; each pooled driver gets it:

```elixir
# config/test.exs
config :playwright, :test, test_id_attribute: "data-pw"
```

At most `workers` drivers run at once; the others wait, first come first served, inside
`BrowserPool.browser/1`: in `setup_all` outside its timeout, in `setup` or a test within ExUnit's
test timeout. A worker is a driver and one browser of one
set of options, as Playwright Test's worker runs one project: a call with other options (another
`browser_name`, `launch_options`, `driver` or `on_start`) takes another worker, which may
restart an idle one of other options. ExUnit runs modules in random order, so in a run that
mixes options each switch restarts a worker (a driver start, about 110 ms, plus the browser's
launch). Run one configuration per invocation, as Playwright Test's projects effectively do: tag
each module with its configuration (`@moduletag browser: :firefox`) and run
`mix test --only browser:firefox`, or give each CI job one. A rare module with unusual options
can be `async: false`, so it doesn't wait behind the others.

Or keep each configuration's workers warm, at the cost of memory: with `workers` above
`max_cases` (up to `max_cases` per configuration), no more than `max_cases` modules hold a worker
at once. A module then finds an idle worker of its options or starts a new one, rather than
restarting another configuration's. LiveView's e2e suite on Chromium, Firefox and WebKit in one
run at `max_cases` 9 took 80 s with 9 workers, 61.8 s with 18 and 57.5 s with 27, at about
11 GB peak memory.

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
launching. It takes `ws_endpoint` and the options of `Playwright.BrowserType.connect/3`:

```elixir
# config/test.exs
config :playwright, :test,
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
config :playwright, :test,
  connect_options: if(url = System.get_env("PW_TEST_CONNECT_WS_ENDPOINT"), do: [ws_endpoint: url])
```

`PW_TEST_CONNECT_WS_ENDPOINT=ws://localhost:3000/ mix test` then runs on remote browsers.

The remote browser must reach your app: set `base_url` to a host the container resolves
(`http://host.docker.internal:4000` on Docker Desktop), or pass `expose_network: "<loopback>"`
so the server tunnels `localhost` to your machine.

## The running test

`Playwright.Test.info/0` is Playwright Test's `test.info()`: the running test's `test_pid`,
`file`, `test_name`, `output_dir`, `timeout` (ExUnit's, `:infinity` for none), `deadline`
(when ExUnit's timeout ends it, in `System.monotonic_time(:millisecond)`) and `close_deadline`
(when the runner closes the test's contexts, just before), in the test's process and in
processes with it in `$callers` (a `Task`, a route handler). A library that owns resources per
test (an Ecto sandbox owner, a session) finds the test from a `Task` with it:
`Playwright.Test.info().test_pid`. Outside a registered test `info/0` raises;
`Playwright.Test.in_registered_test?/0` tells first.

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
explicitly (`env: [{~c"MIX_ENV", ~c"dev"}]` in `Port.open/2`).

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

## Accessibility checks

`@axe-core/playwright` isn't ported: evaluate axe-core's own script in the page (again after each
navigation) and run it:

```elixir
Page.evaluate!(page, File.read!("assets/node_modules/axe-core/axe.min.js"))
%{"violations" => violations} = Page.evaluate!(page, "() => axe.run()")
assert violations == []
```

`axe.run(context, options)` takes what `AxeBuilder`'s `include`, `exclude` and `withTags` set:
`Page.evaluate!(page, "([c, o]) => axe.run(c, o)", [%{include: ["main"]}, %{runOnly: ["wcag2a"]}])`.
Take the axe-core your JS suite's `@axe-core/playwright` resolves, for the same rules. It checks
the main frame only: `AxeBuilder` also runs axe in each iframe and merges the results.

## Porting Playwright Test specs

Most of a spec ports call for call. What differs (and see [Not supported](#not-supported)):

- JS `null` is `:null` (`undefined` is `nil`), and objects from `evaluate` are maps with string
  keys (`result["entry"]["foo"]`). A call that returns `X | null` returns `nil`
  (`Locator.get_attribute!/2` of a missing attribute).
- A JS regex literal PCRE rejects (`/\patched/`: `\p` is `p` in JS without `u`) needs
  `Playwright.RegExp.new/1`, which sends the JS source as it is.
- `elementHandle.evaluate(...)` is `JSHandle.evaluate!(element_handle, ...)`: an `ElementHandle`
  takes the `JSHandle` functions.
- Module-level `let` state reset in `beforeEach` becomes per-test state, returned from `setup` or
  kept in an `Agent` (unlinked when an `on_exit` reads it, see "A check after the test").
- `expect(fn).toPass()` is `Expect.to_pass!/2`, which returns the passing attempt's value: a
  callback that assigns an outer `let` returns it instead (`box = Expect.to_pass!(fn -> ...; box
  end)`). `expect.poll(fn).toBe(x)` is `Expect.poll!(fn, &assert(&1 == x))`, and a call started
  now and awaited later (`const p = locator.evaluate(...)`) is `Playwright.Promise.async/1`, and
  `Promise.all([...])` is `Playwright.Promise.all/1` of those (see [Concurrency](concurrency.md)).
- The `baseURL` fixture is `Playwright.Test.config().context_options[:base_url]`. The `request`
  fixture is a request context of its own, `APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))`,
  which in a test gets the config's `context_options` and is disposed of at its end; it is not
  `Page.request/1` (upstream's `page.request`, which shares the page's cookies).
- `addInitScript(fn)` calls the function, but a string is sent as is, so `"() => ..."` only
  defines one: pass `"(#{fun})()"`, or the function's body.
- A selector with parentheses can't go in `~s(...)`: use `~s[...]` or a string.
- `test.use({ ... })` at a file's top is `use Playwright.Case, context_options: [...]`, in a
  `test.describe` it is `@describetag Test.use(context_options: [...])` (`@tag` for one test);
  `projects` are `parameterize:` with a `Test.parameters/1` map each (see "Devices" and
  "Projects"). When the module's context can't be configured enough (values only
  the module's own `setup` computes, as ExUnit runs the case template's `setup` first, or options
  that differ per test), create the context in the test or its `setup`:
  `Browser.new_context!(browser, storage_state: state)`. It still gets the defaults, the config's
  and the module's options, and is recorded.
- A spec that shares one page from `beforeAll` would still pay for `Playwright.Case`'s context
  and page in each test (about 40 ms on Chromium, 120 ms on Firefox): write the few lines
  instead. The `setup_all` context gets the defaults, the config's, the project's and the
  module's `context_options` and the timeouts, but no test records it (see "Not ported yet"):

  ```elixir
  defmodule MyApp.DashboardTest do
    use ExUnit.Case, async: true
    use Playwright.Test

    alias Playwright.{Browser, BrowserContext, Page}
    alias Playwright.Test.BrowserPool

    setup_all do
      context = Browser.new_context!(BrowserPool.browser())
      on_exit(fn -> BrowserContext.close!(context) end)
      %{page: BrowserContext.new_page!(context)}
    end

    test "shows the list", %{page: page} do
      # ...
    end
  end
  ```

## Not supported

Playwright Test features ExUnit can't host, or that ExUnit and Elixir already cover
([#210](https://github.com/ftes/playwright_ex/issues/210)):

| Playwright Test | why | instead |
|---|---|---|
| runtime `test.skip(condition)` | ExUnit can't skip a running test, and its filters don't see `parameterize:` values | a tag known before the run (`@tag skip: ...`, `--exclude`), or an `if` around the body (reported as passed) |
| `test.fixme`, `test.slow` | ExUnit has tags for both | `@tag :skip`, `@tag timeout: ...` |
| `retries` | ExUnit has no retries in a run | rerun the failures: a `mix test --failed` after a run whose tests failed (exit status 2), as in "Traces, screenshots and videos"; the retry modes (`trace: :on_first_retry`, ...) go by it |
| nested or duplicate-name `describe` | ExUnit's `describe` doesn't nest, and its names are unique in a module | a module per outer `describe` (its `beforeEach` a module `setup`, its `beforeAll` the module's `setup_all`, which a `describe` can't have); a `describe` repeated in a loop becomes one `describe` with the loop inside |
| `fullyParallel` | ExUnit runs a module's tests one after another | a module per `describe`; for `fullyParallel: false` on shared state, a `group:` |
| `describe.serial`, `mode: 'serial'` | ExUnit runs a module's tests in random order | one test, with a `Test.step` per test; modules sharing state in the app in one `group:` (see "Setup") |
| `globalSetup`, project `dependencies` | ExUnit has no projects | `test_helper.exs` (see "Logging in once") |
| asymmetric and value matchers (`expect.objectContaining`, `expect.any(String)`, `toMatchObject`, `toBeCloseTo`, ...) | the jest matchers aren't ported | patterns: `assert %{"id" => id} = hd(list)`, then `assert is_binary(id)`; `assert_in_delta/3` |
| `expect.configure({ timeout, soft })` | the options are the receiver's, not a configured `expect` | the matchers' `timeout:`, `Expect.soft/1` |
| `json`, `junit` reporters | ExUnit formatters cover them | an ExUnit formatter, such as the `junit_formatter` Hex package |
| `list`, `line`, `dot` reporters | ExUnit's output covers them | ExUnit's CLI formatter |
| reporter plugins (monocart coverage, ...) | there are no reporters to plug into | none: `Playwright.Coverage` collects, your code reports |
| `webServer` | `test_helper.exs` starts what a run needs | start the endpoint in `test_helper.exs`, or `server: true` in the test config (see "The app under test") |

Not ported yet ([open an issue](https://github.com/ftes/playwright_ex/issues) if you need one):

- the HTML reporter, with `blob` and `merge-reports` for partitioned runs;
- rebaselining inline aria snapshots into the test source (`--update-source-method`);
- `_defaultLaunchOptions`: a `BrowserType.launch` inside a test doesn't inherit the browser's
  `launch_options`;
- recording `setup_all` contexts per test: a context created in `setup_all` gets the defaults,
  but its actions aren't in a test's trace, and it gets no screenshots or `error-context.md`.
  Playwright Test's `ArtifactsRecorder` records every open context per test, `beforeAll` ones
  included. Create the context per test instead, as `Playwright.Case` does by default;
- function-valued `use` options (Playwright Test's option fixtures, `test.use({ locale: async
  ({}, use) => ... })`): `context_options` are keyword lists;
- the current test's options for a context a long-lived `setup_all` process or handler (one with
  its `$callers`) creates during a test: it gets the module's defaults and no test records it,
  where Playwright Test's `runBeforeCreateBrowserContext` resolves the current test, so the
  context gets that test's options and is recorded in it;
- a fresh worker after a failed test: `setup_all` state, its pages included, carries on into the
  module's next tests, where Playwright Test starts a new worker (and runs `beforeAll` again). A
  call that hangs on a shared page can outlive the failed test: bound such calls with
  `action_timeout`;
- `test.fail` and annotations (`test.info().annotations`, a trace's `annotations` are `[]`):
  they would be tags of the same kind as `Test.use/1`'s, `@tag Test.fail()` and
  `@tag Test.annotate(...)`
  ([#286](https://github.com/ftes/playwright_ex/issues/286));
- a project's own `outputDir`, `snapshotDir` and `snapshotPathTemplate`: `output_dir`,
  `snapshot_dir` and `snapshot_path_template` are config only
  ([#286](https://github.com/ftes/playwright_ex/issues/286));
- the video's step overlay keeps the title of a process killed inside `step/2,3`, and shows an
  IPv6 host with a zone id as `fe80`.

## Coming from Wallaby

Wallaby's queries become locators, and its assertions matchers that wait for the page, so the
`:timer.sleep` calls and retry loops go:

```elixir
# assert_has(session, css(".alert", text: "Saved"))
Page.locator(page, ".alert") |> Locator.filter(has_text: "Saved") |> Expect.to_be_visible!()
# refute_has(session, css(".error"))
Page.locator(page, ".error") |> Expect.not_to_be_visible!()
# Enum.any?(all(session, css("li")), &(Element.text(&1) =~ "Apple"))
Page.get_by_role(page, :listitem) |> Locator.filter(has_text: "Apple") |> Expect.to_be_visible!()
```

Locators are strict, as `assert_has`'s default count of 1 is: a matcher of one element
(`to_be_visible`, `to_have_text` with a string) fails on a locator that matches several, and
`assert_has`'s `count:` is `Expect.to_have_count!/2`. `Element.text` is the rendered text, so a text with CSS `text-transform` needs
`Expect.to_have_text!(locator, "RED", use_inner_text: true)`; `to_have_text!` reads
`textContent`. `fill_in` types key by key, `Locator.fill!/2` sets the value with one `input`
event: for handlers of key events, `Locator.press_sequentially!/3`. For the SQL sandbox, see
[The app under test](#the-app-under-test).
