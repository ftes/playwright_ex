defmodule PlaywrightEx.UpstreamCase do
  @moduledoc """
  Case template for tests mirrored from upstream `tests/` (see `PORTING.md`).

  Fixtures, as upstream's `tests/config/{baseTest,serverFixtures,browserTest}.ts` provide them.
  Upstream's worker-scoped fixtures are module-scoped here (one driver per test module):

    * `playwright`, `browser_name` (`BROWSER` env, default `"chromium"`), `browser_type`,
      `browser` (launched once per module)
    * `server`, `https_server` (`PlaywrightEx.TestServer`, reset before each test),
      `asset` (`asset.("file-to-upload.txt")` is its path under upstream `tests/assets`)
    * `context_factory` (`context_factory.(options)`; its contexts are closed after the test)
    * `context`, `page` for tests tagged `:page` (`@moduletag :page` for `pageTest` specs):
      upstream creates fixtures lazily, here a tag asks for them.
    * `request` (`playwright.request.newContext()`, disposed after the test) for tests tagged
      `:request`, or `request: options` (`newContext` options, for specs that override the fixture)
    * `create_user_data_dir` (`create_user_data_dir.()`, a fresh temp dir, removed after the test),
      `launch_persistent` (`launch_persistent.(options)` returns `%{context: _, page: _}`, closed
      after the test), `start_remote_server` (`start_remote_server.("run-server", options)`,
      `PlaywrightEx.RemoteServer.RunServer`, killed after the test; `launchServer` is not ported)

  Tests call the public API (`PlaywrightEx.BrowserType`, ...), as upstream tests do.
  """
  use ExUnit.CaseTemplate

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.TestServer

  using do
    quote do
      # Set `@upstream "tests/...spec.ts"` before `use`: `mix test --only upstream:<spec>`.
      @moduletag upstream: @upstream
      @moduletag timeout: 120_000
    end
  end

  setup_all %{module: module} do
    # Upstream runs its tests with the driver "under test" (`window.builtins`, ...).
    start_supervised!({PlaywrightEx.Supervisor, name: module, env: [{"PWTEST_UNDER_TEST", "1"}]})
    playwright = PlaywrightEx.playwright(module)
    browser_name = System.get_env("BROWSER", "chromium")
    browser_type = browser_type(playwright, browser_name)

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

  setup %{browser_type: browser_type} do
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

    start_remote_server = fn
      "run-server", options ->
        server = PlaywrightEx.RemoteServer.RunServer.start(options)
        on_exit(fn -> PlaywrightEx.RemoteServer.RunServer.close(server) end)
        server

      "launchServer", _options ->
        raise "not ported: launchServer"
    end

    %{
      create_user_data_dir: create_user_data_dir,
      launch_persistent: launch_persistent,
      start_remote_server: start_remote_server
    }
  end

  defp browser_type(playwright, "chromium"), do: Playwright.chromium(playwright)
  defp browser_type(playwright, "firefox"), do: Playwright.firefox(playwright)
  defp browser_type(playwright, "webkit"), do: Playwright.webkit(playwright)
end
