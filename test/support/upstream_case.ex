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

  Tests call the public API (`PlaywrightEx.BrowserType`, ...), as upstream tests do.
  """
  use ExUnit.CaseTemplate

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Playwright
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

  defp browser_type(playwright, "chromium"), do: Playwright.chromium(playwright)
  defp browser_type(playwright, "firefox"), do: Playwright.firefox(playwright)
  defp browser_type(playwright, "webkit"), do: Playwright.webkit(playwright)
end
