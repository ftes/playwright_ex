defmodule PlaywrightEx.UpstreamCase do
  @moduledoc """
  Case template for tests mirrored from upstream `tests/` (see `PORTING.md`).

  Fixtures, as upstream's `tests/config/{baseTest,serverFixtures,browserTest}.ts` provide them.
  Upstream's worker-scoped fixtures are module-scoped here (one driver per test module):

    * `playwright`, `browser_name` (`BROWSER` env, default `"chromium"`), `browser_type`,
      `browser` (launched once per module)
    * `server`, `https_server` (`PlaywrightEx.TestServer`, reset before each test),
      `asset` (`asset.("file-to-upload.txt")` is its path under upstream `tests/assets`)

  Until the public API is generated, tests call the ported client inside `api/3` (what the
  facade will do), with `launch/2` and `close/1` as shorthands.
  """
  use ExUnit.CaseTemplate

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.BrowserType
  alias PlaywrightEx.Client.Playwright
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.TestServer

  using do
    quote do
      import PlaywrightEx.UpstreamCase

      # Set `@upstream "tests/...spec.ts"` before `use`: `mix test --only upstream:<spec>`.
      @moduletag upstream: @upstream
      @moduletag timeout: 120_000
    end
  end

  setup_all %{module: module} do
    start_supervised!({PlaywrightEx.Supervisor, name: module})
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
      browser: launch(browser_type),
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

  @doc "Runs `fun` as the public API call `api_name` on `receiver` (see `PlaywrightEx.Runtime.Api`)."
  def api(api_name, receiver, fun), do: Api.call(api_name, receiver, fun)

  def launch(browser_type, options \\ %{}),
    do: api("browserType.launch", browser_type, fn -> BrowserType.launch(browser_type, options) end)

  def close(browser, options \\ %{}), do: api("browser.close", browser, fn -> Browser.close(browser, options) end)

  defp browser_type(playwright, "chromium"), do: Playwright.chromium(playwright)
  defp browser_type(playwright, "firefox"), do: Playwright.firefox(playwright)
  defp browser_type(playwright, "webkit"), do: Playwright.webkit(playwright)
end
