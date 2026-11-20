defmodule PlaywrightTest do
  use ExUnit.Case, async: true

  alias Playwright.APIRequest
  alias Playwright.APIRequestContext
  alias Playwright.Browser
  alias Playwright.BrowserContext
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

  test "the static devices are the driver's, as keyword lists", %{playwright: playwright} do
    assert Map.new(Playwright.devices(), fn {name, device} -> {name, Map.new(device)} end) ==
             Playwright.devices(playwright)

    assert Enum.all?(Playwright.devices(), fn {_name, device} -> Keyword.keyword?(device) end)
    iphone = Playwright.device("iPhone 13")
    assert Playwright.devices()["iPhone 13"] == iphone
    assert %{user_agent: _, viewport: %{width: 390}, default_browser_type: "webkit"} = Map.new(iphone)
  end

  test "the config takes a device as it is" do
    config =
      ~s|import Config\nconfig :playwright, :test, browser_name: :firefox\n| <>
        ~s|config :playwright, :test, Playwright.device("iPhone 13")|

    assert [playwright: [test: test]] = Config.Reader.eval!("runtime.exs", config)
    assert test == [browser_name: :firefox] ++ Playwright.device("iPhone 13")
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

    assert_raise ArgumentError, ~r/browserType\.launch: unknown field proxy\.servr, expected one of bypass, /, fn ->
      BrowserType.launch(browser_type, proxy: %{servr: "x"})
    end

    assert_raise ArgumentError, ~r/browserType\.launch: unknown option chromiumSandbox/, fn ->
      BrowserType.launch(browser_type, chromiumSandbox: false)
    end
  end

  test "cookies and storage states: JS keys, checked against the protocol's, results round-trip",
       %{playwright: playwright} do
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    on_exit(fn -> Browser.close(browser) end)
    context = Browser.new_context!(browser)
    url = "https://example.com"

    # The protocol validator would drop `http_only` silently, leaving the cookie readable.
    assert_raise ArgumentError,
                 ~r/^browserContext\.addCookies: unknown field cookies\[1\]\.http_only, expected one of _crHasCrossSiteAncestor, domain, expires, httpOnly, /,
                 fn ->
                   BrowserContext.add_cookies(context, [
                     %{name: "a", value: "b", url: url},
                     %{name: "c", value: "d", url: url, http_only: true}
                   ])
                 end

    assert BrowserContext.cookies!(context) == []
    BrowserContext.add_cookies!(context, [%{name: "a", value: "b", url: url, httpOnly: true}])
    assert [%{name: "a", httpOnly: true} = cookie] = BrowserContext.cookies!(context)

    # Results pass back, protocol-only fields too (Chromium's partitioned cookies have
    # `_crHasCrossSiteAncestor`).
    BrowserContext.add_cookies!(context, BrowserContext.cookies!(context))
    assert BrowserContext.cookies!(context) == [cookie]
    BrowserContext.add_cookies!(context, [Map.put(cookie, :_crHasCrossSiteAncestor, false)])
    state = BrowserContext.storage_state!(context)
    assert %{cookies: [_], origins: []} = state
    assert BrowserContext.cookies!(Browser.new_context!(browser, storage_state: state)) == [cookie]
    BrowserContext.set_storage_state!(context, state)
    request = APIRequest.new_context!(Playwright.request(playwright), storage_state: state)
    APIRequestContext.dispose!(request)

    # Any storage state, as in JS: a request context has no credentials, the validator drops them.
    Playwright.Credentials.create!(BrowserContext.credentials(context), "example.com")
    with_credentials = BrowserContext.storage_state!(context, credentials: true)
    assert %{credentials: [%{rpId: "example.com"}]} = with_credentials
    request = APIRequest.new_context!(Playwright.request(playwright), storage_state: with_credentials)
    APIRequestContext.dispose!(request)

    # A storage state from JSON has string keys, as the protocol validator reads them.
    decoded = state |> JSON.encode!() |> JSON.decode!()
    assert %{"cookies" => [%{"httpOnly" => true}]} = decoded
    assert BrowserContext.cookies!(Browser.new_context!(browser, storage_state: decoded)) == [cookie]

    assert_raise ArgumentError,
                 ~s(browser.newContext: unknown field storage_state."cookie", expected one of "cookies", "credentials", "origins"),
                 fn ->
                   Browser.new_context(browser, storage_state: %{"cookie" => []})
                 end

    assert_raise ArgumentError,
                 ~r/^browser\.newContext: unknown field storage_state\.cookies\[0\]\.http_only, /,
                 fn ->
                   Browser.new_context(browser, storage_state: %{cookies: [%{name: "a", value: "b", http_only: true}]})
                 end

    assert_raise ArgumentError,
                 ~r/^browserContext\.setStorageState: unknown field storage_state\.origins\[0\]\.local_storage, /,
                 fn -> BrowserContext.set_storage_state(context, %{origins: [%{origin: url, local_storage: []}]}) end
  end
end
