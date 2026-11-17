defmodule PlaywrightTest do
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserType
  alias Playwright.PlaywrightError
  alias Playwright.Runtime.Conn
  alias Playwright.TestBrowser

  setup_all do
    start_supervised!({Playwright.Supervisor, name: __MODULE__})
    %{playwright: Playwright.instance(__MODULE__)}
  end

  test "root Playwright object", %{playwright: playwright} do
    assert BrowserType.name(Playwright.chromium(playwright)) == "chromium"
    assert BrowserType.name(Playwright.firefox(playwright)) == "firefox"
    assert BrowserType.name(Playwright.webkit(playwright)) == "webkit"
    assert %{"iPhone 15" => %{user_agent: _, viewport: %{width: _}}} = Playwright.devices(playwright)
  end

  test "the static devices are the driver's", %{playwright: playwright} do
    assert Playwright.devices() == Playwright.devices(playwright)
    assert %{user_agent: _, viewport: %{width: 390}, default_browser_type: "webkit"} = Playwright.devices()["iPhone 13"]
  end

  test "launches and closes the browser", %{playwright: playwright} do
    assert {:ok, browser} = BrowserType.launch(TestBrowser.browser_type(playwright))
    assert inspect(browser) =~ ~r/^#Playwright\.Browser<browser@\w+>$/
    assert Browser.version(browser) =~ ~r/^\d+\.\d+/
    assert Browser.is_connected(browser)
    assert Browser.browser_type(browser) == TestBrowser.browser_type(playwright)
    refute Conn.in_conn?()

    assert Browser.close(browser) == :ok
    refute Browser.is_connected(browser)
    # Closing twice is fine (TargetClosedError is swallowed, as upstream).
    assert Browser.close!(browser, reason: "done") == :ok
  end

  test "disconnected listeners run during close", %{playwright: playwright} do
    test = self()
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    listener = fn b -> send(test, {:disconnected, b}) end
    assert Browser.on(browser, :disconnected, listener) == browser
    Browser.close!(browser)
    assert_received {:disconnected, ^browser}

    assert_raise ArgumentError, ~r/browser\.on: unknown event :closed, expected one of :context, :disconnected/, fn ->
      Browser.on(browser, :closed, listener)
    end
  end

  test "protocol errors carry the API name and the call log", %{playwright: playwright} do
    assert {:error, %PlaywrightError{} = error} =
             BrowserType.launch(TestBrowser.browser_type(playwright), executable_path: "/nonexistent/chrome")

    assert error.message =~ ~r/^browserType\.launch: .*\/nonexistent\/chrome/
    assert is_list(error.log)

    assert_raise PlaywrightError, ~r/^browserType\.launch: /, fn ->
      BrowserType.launch!(TestBrowser.browser_type(playwright), executable_path: "/nonexistent/chrome")
    end
  end

  test "client-side validation errors", %{playwright: playwright} do
    chromium = Playwright.chromium(playwright)

    assert_raise Playwright.Protocol.ValidatorPrimitives.ValidationError,
                 "browserType.launch: args: expected array, got string",
                 fn -> BrowserType.launch!(chromium, args: "--no-sandbox") end
  end

  test "options: snake_case keys, nested objects with JS keys, unknown keys", %{playwright: playwright} do
    browser_type = TestBrowser.browser_type(playwright)

    browser =
      BrowserType.launch!(browser_type, timeout: :infinity, proxy: %{server: "per-context"}, chromium_sandbox: false)

    Browser.close!(browser)

    assert_raise ArgumentError, ~r/browserType\.launch: unknown field :proxy\.servr, expected one of :bypass/, fn ->
      BrowserType.launch(browser_type, proxy: %{servr: "x"})
    end

    assert_raise ArgumentError, ~r/browserType\.launch: unknown option :chromiumSandbox/, fn ->
      BrowserType.launch(browser_type, chromiumSandbox: false)
    end
  end
end
