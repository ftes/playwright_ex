# Debugging and CI

Snippets alias `PlaywrightEx.{Page, BrowserContext, Tracing, ...}`.

## Errors and call logs

A failed call says what it waited for. The message of a `PlaywrightEx.TimeoutError` ends with
the call log, the steps the driver took; `error.log` has them as a list:

```
locator.click: Timeout 1000ms exceeded.
Call log:
  - waiting for getByRole('button', { name: 'Save' })
```

A failed `Expect.*` bang raises `PlaywrightEx.ExpectError` with the expected and received values and
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
mix playwright_ex.cli show-trace tmp/trace.zip
```

or drop the file on [trace.playwright.dev](https://trace.playwright.dev).
[`Tracing.group!/3`](`PlaywrightEx.Tracing.group!/3`) and
[`Tracing.group_end!/1`](`PlaywrightEx.Tracing.group_end!/1`) name a group of steps. In tests,
`PlaywrightEx.Test` traces failing tests, on a rerun or retained on failure ([Testing with
ExUnit](testing-with-exunit.md#traces-screenshots-and-videos)).

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
[`Page.pause!/1`](`PlaywrightEx.Page.pause!/1`) to stop in the Playwright Inspector:

```elixir
PlaywrightEx.playwright() |> Playwright.chromium() |> BrowserType.launch!(headless: false, slow_mo: 500)
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
{PlaywrightEx.Supervisor, env: [{"DEBUG", "pw:api"}]}
```

## GitHub Actions

Install the browsers with their system packages (`--with-deps` runs `apt-get`), and cache the
driver and the browsers. Both are versioned by `playwright_ex` in `mix.lock`:

```yaml
- uses: actions/cache@v6
  with:
    path: |
      ~/.cache/playwright_ex
      ~/.cache/ms-playwright
    key: playwright-${{ runner.os }}-${{ hashFiles('mix.lock') }}
- run: mix playwright_ex.install -- chromium --with-deps
- run: mix test
- uses: actions/upload-artifact@v7
  if: failure()
  with:
    name: test-results
    path: tmp/test-results
```

With a cache hit, only the system packages are installed. If the runner's apt mirror
stalls, this repository's [workflow](https://github.com/ftes/playwright_ex/blob/main/.github/workflows/elixir.yml)
retries and caches the `.deb` files.

`PlaywrightEx.Test.GitHubFormatter` is Playwright Test's `github` reporter: annotations for the
failed tests (at their line), failed `setup_all`s and slow files, and a summary. It prints
only those, so name `ExUnit.CLIFormatter` next to it (`--formatter` replaces the configured
formatters). When failures are rerun, pass it to the first run only, or a test failing twice is
annotated twice:

```yaml
- run: |
    mix test --formatter ExUnit.CLIFormatter --formatter PlaywrightEx.Test.GitHubFormatter ||
      mix test --failed
```

## Docker

Browsers need system libraries, so install them in the image:

```dockerfile
FROM elixir:1.20
WORKDIR /app
COPY mix.exs mix.lock ./
RUN mix local.hex --force && mix deps.get && mix deps.compile
RUN mix playwright_ex.install -- chromium --with-deps
COPY . .
CMD ["mix", "test"]
```

## Remote browsers

Or run the browsers in Playwright's own image and connect to them. The image's version must
match the driver's (`PlaywrightEx.Driver.version/0`):

```sh
docker run -p 3000:3000 --rm --init -it mcr.microsoft.com/playwright:v1.65.0-noble \
  npx -y playwright@1.65.0 run-server --port 3000 --host 0.0.0.0
```

```elixir
browser =
  PlaywrightEx.playwright()
  |> Playwright.chromium()
  |> BrowserType.connect!("ws://localhost:3000/", expose_network: "<loopback>")
```

The local driver still runs; only the browser is remote. `expose_network: "<loopback>"` lets the
remote browser reach `localhost` on your machine, where the app under test runs. For the pooled
browsers of `PlaywrightEx.Test`, set `connect_options`
([Remote browsers](testing-with-exunit.md#remote-browsers)).

More: [trace viewer](https://playwright.dev/python/docs/trace-viewer-intro),
[debugging](https://playwright.dev/python/docs/debug), [CI](https://playwright.dev/python/docs/ci),
[Docker](https://playwright.dev/python/docs/docker).
