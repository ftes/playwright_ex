# Debugging and CI

Snippets alias `Playwright.{Page, BrowserContext, Tracing, ...}`.

## Errors and call logs

A failed call says what it waited for. The message of a `Playwright.TimeoutError` ends with
the call log, the steps the driver took; `error.log` has them as a list:

```
locator.click: Timeout 1000ms exceeded.
Call log:
  - waiting for getByRole('button', { name: 'Save' })
```

A failed `Expect.*` bang raises `Playwright.ExpectError` with the expected and received values and
the same log. Most failures are clear from that alone.

## Traces

A trace records every action with DOM snapshots, screenshots, network and console, and is the
best tool for a failure you can't reproduce locally:

```elixir
tracing = BrowserContext.tracing(context)
Tracing.start!(tracing, screenshots: true, snapshots: true, sources: true)
# ... the test
Tracing.stop!(tracing, path: "tmp/trace.zip")
```

Open it in the trace viewer (it opens a browser window):

```sh
mix playwright.cli show-trace tmp/trace.zip
```

or drop the file on [trace.playwright.dev](https://trace.playwright.dev).
[`Tracing.group!/3`](`Playwright.Tracing.group!/3`) and
[`Tracing.group_end!/1`](`Playwright.Tracing.group_end!/1`) name a group of steps. In tests,
`Playwright.Test` traces failing tests, on a rerun or retained on failure ([Testing with
ExUnit](test-artifacts.md#traces-screenshots-and-videos)).

## Screenshots and videos

```elixir
Page.screenshot!(page, path: "tmp/page.png", full_page: true)
Page.get_by_role(page, :dialog) |> Locator.screenshot!(path: "tmp/dialog.png")
```

Without `path:`, `screenshot!` returns the PNG as a binary. For videos, record a context; each
page's video is written when its context closes:

```elixir
context = Browser.new_context!(browser, record_video: %{dir: "tmp/videos"})
page = BrowserContext.new_page!(context)
# ... the test
BrowserContext.close!(context)
Page.video(page) |> Video.path!()
```

## Console and page errors

Forward the page's console and uncaught errors to the test process or the log:

```elixir
require Logger

BrowserContext.on(context, :console, &Logger.info("console.#{ConsoleMessage.type(&1)}: #{ConsoleMessage.text(&1)}"))
BrowserContext.on(context, :web_error, &Logger.error(Exception.message(WebError.error(&1))))
```

`Page.on(page, :page_error, fun)` gets one page's errors as exceptions. A test can also fail on
them: send them to the test process and `refute_received` at the end.

## Watching it run

Headless is the default. Locally, run a headed browser slowed down, and
[`Page.pause!/1`](`Playwright.Page.pause!/1`) to stop in the Playwright Inspector:

```elixir
Playwright.instance() |> Playwright.chromium() |> BrowserType.launch!(headless: false, slow_mo: 500)
```

`PWDEBUG=1` opens the Playwright Inspector, as in Playwright Test. Run one test with
`--trace`:

```sh
PWDEBUG=1 mix test --trace test/my_app/sign_up_test.exs:12
```

`--trace` removes ExUnit's timeout and runs one test at a time, as Playwright Test's `--debug`
sets no timeout and one worker. Without it, ExUnit's timeout ends the test mid-inspection, and its
contexts close.

The driver's own logs go to stderr with `DEBUG=pw:api` in its environment:

```elixir
{Playwright.Supervisor, env: [{"DEBUG", "pw:api"}]}
```

## GitHub Actions

Install the browsers with their system packages (`--with-deps` runs `apt-get`). Set `MIX_ENV`
for the whole job, so every task shares the test build: the install in `:dev` would compile the
dev deps too.

```yaml
env:
  MIX_ENV: test
steps:
  # ... checkout, erlef/setup-beam
  - run: mix deps.get
  - run: mix playwright.install chromium --with-deps
  - run: mix test
  - uses: actions/upload-artifact@v7
    if: ${{ !cancelled() }}
    with:
      name: test-results
      path: test-results
```

Upload unless cancelled, not only on `failure()`: when failures are rerun (see
[Annotations](#annotations)), a job the rerun turned green still has the first run's files.

Cache neither the driver nor the browsers. On `ubuntu-latest` (26.04) a cold driver download
takes about 2 s and Chromium about 8 s, while restoring a cache of both takes about 3 s: it saves
roughly 6 s per job and churns the cache on every Playwright bump. For Chromium, with the system
libraries already on the image, `--with-deps` installs only 9 font packages (21 MB), and caching
them (`cache-apt-pkgs-action`, or the `.deb` files) didn't speed up the roughly 14 s step, which
`apt-get update` and dpkg dominate. WebKit's system packages are about 140 MB, and the runner's
apt mirror has stalled for whole attempts, so this library's CI caches the `.deb` files and
bounds each attempt. Upstream
[advises the same](https://playwright.dev/docs/ci): restoring a browser cache takes about as
long as downloading, and operating system dependencies aren't cacheable. For reference, if your
network is slow or you run offline: the driver goes to `~/.cache/playwright`
(`~/Library/Caches/playwright` on macOS; the `:cache_dir` option moves it), the browsers to
`~/.cache/ms-playwright` (`~/Library/Caches/ms-playwright` on macOS, or
`PLAYWRIGHT_BROWSERS_PATH`).

### In Playwright's image

Or run the job in Playwright's image, which has every browser (at `PLAYWRIGHT_BROWSERS_PATH`)
and its system packages, so only the driver is installed. Its tag is the pinned driver's
version, not this package's: `mix playwright.cli --version` prints it (`Version 1.65.1`, or
with `executable:` that CLI's version, the tag then), and the README names it. Install with
`--no-browsers` there: an image that lacks the driver's browsers then fails at launch with
Playwright's "Please update docker image as well", instead of `mix playwright.install`
downloading them on every run.
`erlef/setup-beam` needs `unzip`, `ImageOS` and `HOME` there. It pays off with WebKit or many
browser jobs. The image is about 2 GB, pulled per job on hosted runners, and it is Ubuntu 24.04:
a `_build` (with NIFs) or a cached OTP from a job on `ubuntu-latest` may not run in it, so build
in the image too. Services are reached by name, not `localhost`.

```yaml
runs-on: ubuntu-24.04
container:
  image: mcr.microsoft.com/playwright:v1.65.1-noble
env:
  MIX_ENV: test
  ImageOS: ubuntu22
  HOME: /root
steps:
  - uses: actions/checkout@v6
  - run: apt-get update && apt-get -y install unzip
  - uses: erlef/setup-beam@v1
    with:
      elixir-version: "1.20"
      otp-version: "29"
  - run: mix deps.get
  - run: mix playwright.install --no-browsers
  - run: mix test
```

### Annotations

`Playwright.Test.GitHubFormatter` is Playwright Test's `github` reporter: annotations for the
failed tests (at their line), failed `setup_all`s and slow files, and a summary. It prints
only those, so name `ExUnit.CLIFormatter` next to it (`--formatter` replaces the configured
formatters). When failures are rerun, pass it to the rerun too: as upstream annotates every
attempt, a test failing twice gets an error per run (the rerun's under `Retry #1`), and one
passing on the rerun counts as flaky in the rerun's summary (so does one that a failed
`setup_all` kept from running in the first run, where upstream counts it as passed). As it
takes a `mix test --failed` run for retry 1, a local `--failed` rerun after a fix lists every
fixed test as flaky: the formatter is meant for CI. Rerun
only on exit status 2 (tests failed): any other failure, such as a crash or a missed coverage
threshold, would otherwise go green on an empty `--failed` run.
On Elixir 1.20 and earlier, `--failed` loses some failures: see
[Retries](test-artifacts.md#retries).
`erlef/setup-beam`'s problem matchers annotate each failure again, at the test's line, so turn
them off:

```yaml
- uses: erlef/setup-beam@v1
  with:
    elixir-version: "1.20"
    otp-version: "29"
    disable_problem_matchers: true
- run: |
    f="--formatter ExUnit.CLIFormatter --formatter Playwright.Test.GitHubFormatter"
    mix test $f || { [ $? -eq 2 ] && mix test --failed $f; }
```

With `--partitions`, rerun without it. The failures manifest holds only this partition's
failures, and `mix test` deals the files to the partitions round-robin, so `--partitions` would
deal them again: a partition reruns only some of its failures, possibly none, and can exit 0.

```yaml
- env:
    MIX_TEST_PARTITION: ${{ matrix.partition }}
  run: mix test --partitions 4 || { [ $? -eq 2 ] && mix test --failed; }
```

## Docker

Browsers need system libraries, so install them in the image:

```dockerfile
FROM elixir:1.20
ENV MIX_ENV=test
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix deps.get && mix deps.compile
RUN mix playwright.install chromium --with-deps
COPY . .
CMD ["mix", "test"]
```

## Remote browsers

When the tests can't run in Playwright's image (local development on macOS, or an app's own
image), run only the browsers there and connect to them. The image's version must match the
driver's (`Playwright.Driver.version/0`):

```sh
docker run -p 3000:3000 --rm --init -it mcr.microsoft.com/playwright:v1.65.1-noble \
  npx -y playwright@1.65.1 run-server --port 3000 --host 0.0.0.0
```

```elixir
browser =
  Playwright.instance()
  |> Playwright.chromium()
  |> BrowserType.connect!("ws://localhost:3000/", expose_network: "<loopback>")
```

The local driver still runs; only the browser is remote. `expose_network: "<loopback>"` lets the
remote browser reach `localhost` on your machine, where the app under test runs. For the pooled
browsers of `Playwright.Test`, set `connect_options`
([Remote browsers](test-artifacts.md#remote-browsers)).

More: [trace viewer](https://playwright.dev/python/docs/trace-viewer-intro),
[debugging](https://playwright.dev/python/docs/debug), [CI](https://playwright.dev/python/docs/ci),
[Docker](https://playwright.dev/python/docs/docker).
