# Artifacts, retries and workers

What `Playwright.Test` records, how to rerun failures, and how the browser pool runs. The
reference is `Playwright.Test`'s [Artifacts](Playwright.Test.html#module-artifacts) and
`Playwright.Test.BrowserPool`. Snippets alias `Playwright.{Browser, BrowserContext, Test}` and
`Playwright.Test.BrowserPool`.

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
keep the files of failures; a passing test's are dropped at its end. They are options of every
level ([Options, devices and projects](test-options.md)), as a mode:

```elixir
use Playwright.Case, trace: :retain_on_failure, video: :retain_on_failure

@tag Test.use(trace: :on)
test "checks out", %{page: page} do
  # ...
end
```

As in Playwright Test, they take options too, with the mode as `:mode`: `trace: [mode: :on,
snapshots: false]`, `screenshot: [mode: :only_on_failure, full_page: true]`, `video: [mode: :on,
size: %{width: 640, height: 480}, fps: 10, show: %{test: %{level: "step"}}]` (`show.test` writes
the test's title and steps over the video). Each replaces the value under it as a whole; an
unknown `use` option fails the module's compilation, and an unknown mode records nothing, as
upstream's.

Files of your own go in the test's dir with `Playwright.Test.output_path("export.csv")`; they
stay when the test passes. `Playwright.Test.attach("export", path: path)` (or `body:`) also shows
one in the trace, as Playwright Test's `testInfo.attach`.

The files are written in the test's `on_exit`, which ExUnit runs in reverse order of
registration. An `on_exit` that reads them (to check a `trace.zip`, say) must therefore be
registered before the recording's: in a `setup` above `use Playwright.Test`.
`Playwright.Test.info(test_pid)` there has the test's result, as Playwright Test's `testInfo` has
it in teardown (`status`, `errors`, `duration`):

```elixir
setup %{test_pid: test_pid} do
  on_exit(fn ->
    %{status: status, output_dir: dir} = Playwright.Test.info(test_pid)
    if status != :passed, do: MyApp.CI.upload(Path.join(dir, "trace.zip"))
  end)
end

use Playwright.Test
```

## Retries

Tracing slows every test. Playwright Test's answer is to trace only the retry of a failure
(`on-first-retry`). ExUnit has no retries in a run, but `mix test --failed` is one: under it a
test is Playwright Test's first retry (`Playwright.Test.info().retry` is 1), and the retry
modes go by it. So trace only the rerun:

```elixir
# config/test.exs
config :playwright, :test, trace: :on_first_retry
```

and rerun the failures in CI, only on exit status 2 (tests failed; a crash or a missed
`--cover` threshold isn't retried, and an empty `--failed` run would pass):

```sh
mix test || { [ $? -eq 2 ] && mix test --failed; }
```

Call `mix test` itself, not through an alias that runs it with `mix cmd`: `mix cmd` turns exit
status 2 into 1, so the retry never fires. In CI, with `--partitions` and annotations:
[Annotations](debugging-and-ci.md#annotations).

<!-- remove with Elixir 1.21: ftes/playwright_ex#319 -->
On Elixir 1.20 and earlier, `--failed` can miss a failure, and the retry then passes or runs
nothing and exits 0: a test of a `parameterize:` module ([Projects](test-options.md#projects)) passing with
another parameter set later in the run erases its failure
([elixir-lang/elixir#15820](https://github.com/elixir-lang/elixir/issues/15820)), as does a
`setup_all`'s `on_exit` failing after its tests passed
([elixir-lang/elixir@0f654791](https://github.com/elixir-lang/elixir/commit/0f654791)). Running
one project per `mix test` avoids the common case, the same test in another project. Failures
across your own parameter lists, and that `on_exit` failure, can still be lost. In CI, run one
project per job, each the job from [GitHub Actions](debugging-and-ci.md#github-actions) with its
project's browser and an artifact name of its own (`test-results-${{ matrix.browser }}`):

```yaml
strategy:
  fail-fast: false
  matrix:
    include:
      - {project: "Desktop Chrome", browser: chromium}
      - {project: "Desktop Firefox", browser: firefox}
      - {project: "Desktop Safari", browser: webkit}
steps:
  # ...
  - run: mix playwright.install ${{ matrix.browser }} --with-deps
  - env:
      PROJECTS: ${{ matrix.project }}
    run: mix test || { [ $? -eq 2 ] && mix test --failed; }
```

A rerun that lost every failure prints `There are no tests to run` and exits 0, and no
`mix test` flag turns that into a failure, so check its output, in a bash step (`retry` passes
its arguments on, such as the formatters). A rerun that runs only the failures it kept still
passes:

```yaml
- shell: bash
  run: |
    retry() {
      mix test --failed "$@" 2>&1 | tee "$RUNNER_TEMP/retry.log"; s=${PIPESTATUS[0]}
      if grep -q "^There are no tests to run" "$RUNNER_TEMP/retry.log"; then return 1; fi
      return $s
    }
    mix test || { [ $? -eq 2 ] && retry; }
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

A flaky test that passes on the rerun keeps that passing run's trace; for the failure's own too,
`:retain_on_failure_and_retries`. Which dirs a run deletes, and `preserve_output`:
[Artifacts](Playwright.Test.html#module-artifacts).

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

At most `workers` drivers run at once (config, default half the schedulers, as Playwright Test's
`workers`); the others wait, first come first served, inside `BrowserPool.browser/1`: in
`setup_all` outside its timeout, in `setup` or a test within ExUnit's test timeout. A wait in
`setup_all` costs nothing, so ExUnit's `max_cases` can stay as it is; one in `setup` or a test
counts against the test's timeout. A worker is a driver and one browser of one
set of options, as Playwright Test's worker runs one project: a call with other options (another
`browser_name`, `headless`, `channel`, `launch_options`, `connect_options`, `driver` or
`on_start`) takes another worker, which may
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

To watch one module run headed, slowed down, give it a browser with those options:

```elixir
@moduletag :debug

setup_all do
  %{browser: BrowserPool.browser(headless: false, launch_options: [slow_mo: 500])}
end

setup %{browser: browser} do
  context = Browser.new_context!(browser)
  %{context: context, page: BrowserContext.new_page!(context)}
end
```

and run it alone: `mix test test/my_app/sign_up_test.exs`, or `mix test --only debug`. The
call's `launch_options` merge over the module's (its own or its project's, else the config's)
one key at a time, so the other launch options stay. `headless` and `channel`, set at any level,
win over the launch options', as Playwright Test's: pass `headless: false` itself, not in
`launch_options`.

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
are recorded, as on a launched one. The launch options, with `headless` and `channel` over them,
go to the server in the `x-playwright-launch-options` header, as Playwright Test sends them; the server applies those
it allows (`headless`, `channel`, `slow_mo`, ...). A connected browser and a launched one are
different browsers, also of one `browser_name`, and a lost connection is made again by the next
call. Each driver connects once, and the server launches a browser per connection, so each
worker has a browser of its own, as each Playwright Test worker does.

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
