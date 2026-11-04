defmodule PlaywrightEx.Library.BrowsertypeConnectTest do
  @upstream "tests/library/browsertype-connect.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.RemoteServer.RunServer

  # The `connect` fixture: browsers are closed after the test.
  defp connect(browser_type, ws_endpoint, options \\ []) do
    options = Map.new(options)
    headers = Map.merge(%{"x-playwright-launch-options" => JSON.encode!(%{})}, options[:headers] || %{})
    browser = BrowserType.connect!(browser_type, ws_endpoint, Map.put(options, :headers, headers))
    on_exit(fn -> Browser.close(browser) end)
    browser
  end

  describe "run-server" do
    test "should be able to reconnect to a browser", %{browser_type: browser_type, start_remote_server: start_remote_server, server: server} do
      remote_server = start_remote_server.("run-server", %{})
      browser = connect(browser_type, RunServer.ws_endpoint(remote_server))
      browser_context = Browser.new_context!(browser)
      assert BrowserContext.pages(browser_context) == []
      page = BrowserContext.new_page!(browser_context)
      assert Page.evaluate!(page, "11 * 11") == 121
      Page.goto!(page, server.empty_page)
      Browser.close!(browser)

      browser = connect(browser_type, RunServer.ws_endpoint(remote_server))
      browser_context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(browser_context)
      Page.goto!(page, server.empty_page)
      Browser.close!(browser)
    end
  end
end
