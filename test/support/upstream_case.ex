defmodule PlaywrightEx.UpstreamCase do
  @moduledoc """
  Case template for tests mirrored from upstream `tests/` (see `PORTING.md`).

  Fixtures, as upstream's `tests/config/{baseTest,serverFixtures,browserTest}.ts` provide them.
  Upstream's worker-scoped fixtures are module-scoped here (one driver per test module):

    * `playwright`, `browser_name` (`BROWSER` env, default `"chromium"`), `headless` (`HEADED`
      env, see `PlaywrightEx.TestBrowser.headless/0`), `browser_type`, `browser` (launched once
      per module)
    * `server`, `https_server` (`PlaywrightEx.TestServer`, reset before each test),
      `asset` (`asset.("file-to-upload.txt")` is its path under upstream `tests/assets`)
    * `context_factory` (`context_factory.(options)`; its contexts are closed after the test)
    * `context`, `page` for tests tagged `:page` (`@moduletag :page` for `pageTest` specs):
      upstream creates fixtures lazily, here a tag asks for them.
    * `request` (`playwright.request.newContext()`, disposed after the test) for tests tagged
      `:request`, or `request: options` (`newContext` options, for specs that override the fixture)
    * `create_user_data_dir` (`create_user_data_dir.()`, a fresh temp dir, removed after the test),
      `launch_persistent` (`launch_persistent.(options)` returns `%{context: _, page: _}`, closed
      after the test), `start_remote_server` (`start_remote_server.(kind, options)`: kind
      `"run-server"` (`PlaywrightEx.RemoteServer.RunServer`) or `"launchServer"`
      (`PlaywrightEx.RemoteServer`), closed after the test)
    * `launch_server` (`launch_server.(options)` for `browserType.launchServer(options)`:
      `{:ok, PlaywrightEx.RemoteServer.LaunchServer}` or `{:error, message}`, killed after the test)

  Each driver's Playwright gets Playwright Test's defaults (`setup_playwright/2`): no action
  timeout, the default launch options (`headless`, `tracesDir`, ...) and context options (`locale:
  "en-US"`, a 1280x720 viewport, ...). A test that needs a driver of its own (another `env`) starts
  it with `start_playwright/2`.

  Tests call the public API (`PlaywrightEx.BrowserType`, ...), as upstream tests do.

  `test` skips a test that a rule in `test/upstream_not_ported.txt` rules out (`skip: "not
  ported: <reason>"`, over the test's own skip tags), so a bodiless test needs no tag of its own.
  See `Mix.PlaywrightEx.TestRegistry`.
  """
  use ExUnit.CaseTemplate

  alias Mix.PlaywrightEx.TestRegistry
  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.TestServer

  using do
    quote do
      import ExUnit.Case, only: [describe: 2]
      import PlaywrightEx.UpstreamCase, only: [test: 1, test: 2, test: 3, start_playwright: 2]

      # Set `@upstream "tests/...spec.ts"` before `use`: `mix test --only upstream:<spec>`.
      @moduletag upstream: @upstream
      # tests/library/playwright.config.ts: `timeout: video || (darwin && x64) ? 60000 : 30000`
      # (we never record video); `test.slow()` triples it: `@tag timeout: @slow_timeout`.
      @moduletag timeout: PlaywrightEx.UpstreamCase.timeout()
      @slow_timeout 3 * PlaywrightEx.UpstreamCase.timeout()
    end
  end

  @doc "Upstream's per-test timeout (`tests/library/playwright.config.ts`)."
  def timeout do
    darwin_x64 =
      match?({:unix, :darwin}, :os.type()) and
        String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "x86_64")

    if darwin_x64, do: 60_000, else: 30_000
  end

  @doc "`ExUnit.Case.test/1`, skipped when a rule rules it out."
  defmacro test(message) do
    quote do
      PlaywrightEx.UpstreamCase.__not_ported__(__MODULE__, unquote(message))
      ExUnit.Case.test(unquote(message))
    end
  end

  @doc "`ExUnit.Case.test/3`, skipped when a rule rules it out."
  defmacro test(message, var \\ quote(do: _), contents) do
    quote do
      PlaywrightEx.UpstreamCase.__not_ported__(__MODULE__, unquote(message))
      ExUnit.Case.test(unquote(message), unquote(var), unquote(contents))
    end
  end

  @root Path.expand("../..", __DIR__)

  # Playwright Test's option fixtures with no value given (`packages/playwright/src/index.ts`
  # `playwrightFixtures`, as `_combinedContextOptions` collects them): `contextOptions` is `{}`.
  @context_defaults %{
    acceptDownloads: true,
    bypassCSP: false,
    colorScheme: "light",
    contrast: "no-preference",
    forcedColors: "none",
    hasTouch: false,
    ignoreHTTPSErrors: false,
    isMobile: false,
    javaScriptEnabled: true,
    locale: "en-US",
    offline: false,
    reducedMotion: "no-preference",
    viewport: %{width: 1280, height: 720},
    serviceWorkers: "allow"
  }

  @doc """
  Sets up a Playwright instance as Playwright Test's fixtures do (`packages/playwright/src/index.ts`):

    * `_setupContextOptions`: `playwright._defaultContextTimeout = actionTimeout || 0` (likewise
      navigation): no action timeout, the test timeout bounds it.
    * `_browserOptions`: `playwright._defaultLaunchOptions` (`handleSIGINT: false`, `headless`,
      `tracesDir`, `artifactsDir`), merged into every launch.
    * the instrumentation listener's `runBeforeCreateBrowserContext` and
      `runBeforeCreateRequestContext`: the context option defaults (`locale: "en-US"`, a 1280x720
      viewport, ...), for each option the caller did not give, in every `newContext`,
      `launchPersistentContext` and `request.newContext`.

  `artifacts_dir` stands in for the worker's artifacts dir (`artifacts_dir/0`), the caller removes it.
  """
  def setup_playwright(playwright, artifacts_dir) do
    defaults = context_defaults()

    Api.call(nil, playwright, fn ->
      Heap.put(playwright, :_defaultContextTimeout, 0)
      Heap.put(playwright, :_defaultContextNavigationTimeout, 0)

      Heap.put(playwright, :_defaultLaunchOptions, %{
        handleSIGINT: false,
        tracesDir: Path.join(artifacts_dir, "traces"),
        artifactsDir: artifacts_dir,
        headless: TestBrowser.headless()
      })

      # `if (!(key in options)) options[key] = value;`
      ClientInstrumentation.add_listener(Heap.get(playwright, :_instrumentation), %{
        runBeforeCreateBrowserContext: &Map.merge(defaults, &1),
        runBeforeCreateRequestContext: &Map.merge(defaults, &1)
      })
    end)
  end

  @doc """
  A driver of the test's own, started with `env` (as upstream sets `process.env` for one test) and
  set up as the module's (`setup_playwright/2`); stopped after the test. Returns its Playwright.
  """
  def start_playwright(name, env) do
    start_supervised!({PlaywrightEx.Supervisor, name: name, env: [{"PWTEST_UNDER_TEST", "1"} | env]}, id: name)
    playwright = PlaywrightEx.playwright(name)
    artifacts_dir = artifacts_dir()
    on_exit(fn -> File.rm_rf(artifacts_dir) end)
    setup_playwright(playwright, artifacts_dir)
    playwright
  end

  @doc "A fresh artifacts dir (`testInfo._tracing.artifactsDir()`), for `setup_playwright/2`."
  def artifacts_dir do
    dir = Path.join(System.tmp_dir!(), "playwright-ex-artifacts-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "traces"))
    dir
  end

  # `baseURL` is `process.env.PLAYWRIGHT_TEST_BASE_URL`.
  defp context_defaults do
    case System.get_env("PLAYWRIGHT_TEST_BASE_URL") do
      nil -> @context_defaults
      base_url -> Map.put(@context_defaults, :baseURL, base_url)
    end
  end

  @doc false
  # Tags the next test `skip: "not ported: <reason>"` when a rule rules it out. The last `@tag`
  # wins, so the rule wins over the test's own skip tags.
  def __not_ported__(module, name) do
    # ExUnit keeps the current describe in `@ex_unit_describe` ({line, name, counter}).
    describe =
      case Module.get_attribute(module, :ex_unit_describe) do
        {_line, describe, _counter} -> describe
        _ -> nil
      end

    # Modules with no `@upstream` (our own tests on this case) have no registry tests.
    upstream = Module.get_attribute(module, :upstream)
    reason = upstream && TestRegistry.not_ported_reason(@root, upstream, describe, name)
    if reason, do: Module.put_attribute(module, :tag, skip: "not ported: " <> reason)
  end

  setup_all %{module: module} do
    # Upstream runs its tests with the driver "under test" (`window.builtins`, ...).
    start_supervised!({PlaywrightEx.Supervisor, name: module, env: [{"PWTEST_UNDER_TEST", "1"}]})
    playwright = PlaywrightEx.playwright(module)
    artifacts_dir = artifacts_dir()
    on_exit(fn -> File.rm_rf(artifacts_dir) end)
    setup_playwright(playwright, artifacts_dir)

    browser_name = TestBrowser.name()
    browser_type = TestBrowser.browser_type(playwright)

    assets = Path.join(PlaywrightEx.Upstream.ensure!(), "tests/assets")
    cached = Path.join(assets, "cached")

    server = TestServer.server(start_supervised!({TestServer, dir_path: assets}, id: :server))
    TestServer.enable_http_cache(server, cached)

    https_server =
      TestServer.server(
        start_supervised!({TestServer, dir_path: assets, ssl_options: TestServer.cert_options()}, id: :https_server)
      )

    TestServer.enable_http_cache(https_server, cached)

    %{
      playwright: playwright,
      browser_name: browser_name,
      headless: TestBrowser.headless(),
      browser_type: browser_type,
      browser: BrowserType.launch!(browser_type),
      server: server,
      https_server: https_server,
      asset: fn path -> Path.join([assets | String.split(path, "/")]) end
    }
  end

  setup %{server: server, https_server: https_server} do
    TestServer.reset(server)
    TestServer.reset(https_server)
    :ok
  end

  # Upstream restarts the worker after a failed test; here the module's driver lives on. Close
  # the contexts a test left open (say, a browser it launched and never closed), or one still
  # tracing would add its stacks to the traces of the next tests.
  setup %{playwright: playwright} do
    contexts = fn -> Api.call(nil, playwright, fn -> Client.Playwright._all_contexts(playwright) end) end
    before = contexts.()
    on_exit(fn -> for context <- contexts.() -- before, do: BrowserContext.close(context) end)
  end

  setup %{browser: browser} do
    {:ok, contexts} = Agent.start(fn -> [] end)

    context_factory = fn options ->
      context = Browser.new_context!(browser, options)
      Agent.update(contexts, &[context | &1])
      context
    end

    on_exit(fn ->
      for context <- Agent.get(contexts, & &1), do: BrowserContext.close(context)
      Agent.stop(contexts)
    end)

    %{context_factory: context_factory}
  end

  setup %{context_factory: context_factory} = tags do
    if tags[:page] do
      context = context_factory.([])
      %{context: context, page: BrowserContext.new_page!(context)}
    else
      :ok
    end
  end

  setup %{playwright: playwright} = tags do
    if options = tags[:request] do
      request = APIRequest.new_context!(Playwright.request(playwright), if(options == true, do: [], else: options))
      on_exit(fn -> APIRequestContext.dispose(request) end)
      %{request: request}
    else
      :ok
    end
  end

  setup %{browser_type: browser_type, browser_name: browser_name} do
    create_user_data_dir = fn ->
      dir = Path.join(System.tmp_dir!(), "playwright-test-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      dir
    end

    launch_persistent = fn options ->
      user_data_dir = create_user_data_dir.()
      context = BrowserType.launch_persistent_context!(browser_type, user_data_dir, options)
      on_exit(fn -> BrowserContext.close(context) end)
      %{context: context, page: hd(BrowserContext.pages(context))}
    end

    # Upstream also waits 1 s after `server.close()` for its reused workers' browsers.
    start_remote_server = fn kind, options ->
      server =
        case kind do
          "run-server" -> PlaywrightEx.RemoteServer.RunServer.start(options)
          "launchServer" -> PlaywrightEx.RemoteServer._start(browser_type, options)
        end

      on_exit(fn -> PlaywrightEx.RemoteServer.PlaywrightServer.close(server) end)

      server
    end

    launch_server = fn options ->
      with {:ok, server} <- PlaywrightEx.RemoteServer.LaunchServer.start(browser_name, options) do
        on_exit(fn -> PlaywrightEx.RemoteServer.LaunchServer.kill(server) end)
        {:ok, server}
      end
    end

    %{
      create_user_data_dir: create_user_data_dir,
      launch_persistent: launch_persistent,
      start_remote_server: start_remote_server,
      launch_server: launch_server
    }
  end
end
