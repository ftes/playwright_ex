defmodule Playwright.Client.BytesTest do
  # Elixir only: a binary that is not UTF-8 is bytes where JS takes a string or a Buffer
  # (`ClientHelper.is_string/1`), as no JS string is: it can't go as a JSON string.
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserType
  alias Playwright.Page
  alias Playwright.Response
  alias Playwright.Route
  alias Playwright.TestBrowser
  alias Playwright.WebSocketRoute

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 255>>

  setup_all do
    start_supervised!({Playwright.Supervisor, name: __MODULE__})
    browser = BrowserType.launch!(TestBrowser.browser_type(Playwright.instance(__MODULE__)))
    on_exit(fn -> Browser.close(browser) end)
    %{browser: browser}
  end

  test "a fulfilled body that is not UTF-8 is sent as bytes", %{browser: browser} do
    page = Browser.new_page!(browser)
    Page.route!(page, "**/*", &Route.fulfill!(&1, body: @png, content_type: "image/png"))
    response = Page.goto!(page, "http://bytes.test/")
    assert Response.body!(response) == @png
    assert Response.headers(response)["content-length"] == "10"
  end

  test "a WebSocket route's message that is not UTF-8 is a binary frame", %{browser: browser} do
    page = Browser.new_page!(browser)
    Page.route_web_socket!(page, "**/*", &WebSocketRoute.send(&1, @png))

    assert Page.evaluate!(page, """
           () => new Promise(resolve => {
             const ws = new WebSocket('ws://bytes.test/');
             ws.binaryType = 'arraybuffer';
             ws.onmessage = event => resolve([...new Uint8Array(event.data)]);
           })
           """) == :binary.bin_to_list(@png)
  end
end
