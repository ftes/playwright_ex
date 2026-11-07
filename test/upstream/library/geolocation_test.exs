defmodule PlaywrightEx.Library.GeolocationTest do
  @upstream "tests/library/geolocation.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Page

  @get_current_position """
  () => new Promise(resolve => navigator.geolocation.getCurrentPosition(position => {
    resolve({ latitude: position.coords.latitude, longitude: position.coords.longitude });
  }))
  """

  test "GE-001 should work @smoke", %{server: server, context_factory: context_factory} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    BrowserContext.grant_permissions!(context, ["geolocation"])
    Page.goto!(page, server.empty_page)
    BrowserContext.set_geolocation!(context, %{longitude: 10, latitude: 10})
    geolocation = Page.evaluate!(page, @get_current_position)
    assert geolocation == %{"latitude" => 10, "longitude" => 10}
  end

  test "GE-002 should throw when invalid longitude", %{context_factory: context_factory} do
    context = context_factory.([])
    {:error, error} = BrowserContext.set_geolocation(context, %{longitude: 200, latitude: 10})
    assert Exception.message(error) =~ "geolocation.longitude: precondition -180 <= LONGITUDE <= 180 failed."
  end

  test "GE-003 should isolate contexts", %{server: server, context_factory: context_factory, browser: browser} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    BrowserContext.grant_permissions!(context, ["geolocation"])
    BrowserContext.set_geolocation!(context, %{longitude: 10, latitude: 10})
    Page.goto!(page, server.empty_page)

    context2 =
      Browser.new_context!(browser,
        permissions: ["geolocation"],
        geolocation: %{longitude: 20, latitude: 20}
      )

    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)

    geolocation = Page.evaluate!(page, @get_current_position)
    assert geolocation == %{"latitude" => 10, "longitude" => 10}

    geolocation2 = Page.evaluate!(page2, @get_current_position)
    assert geolocation2 == %{"latitude" => 20, "longitude" => 20}

    BrowserContext.close!(context2)
  end

  test "GE-004 should throw with missing latitude", %{context_factory: context_factory} do
    context = context_factory.([])
    # @ts-expect-error setGeolocation must have latitude
    {:error, error} = BrowserContext.set_geolocation(context, %{longitude: 10})
    assert Exception.message(error) =~ "geolocation.latitude: expected float, got undefined"
  end

  test "GE-005 should not modify passed default options object", %{browser: browser} do
    geolocation = %{longitude: 10, latitude: 10}
    options = [geolocation: geolocation]
    context = Browser.new_context!(browser, options)
    BrowserContext.set_geolocation!(context, %{longitude: 20, latitude: 20})
    assert options[:geolocation] == geolocation
    BrowserContext.close!(context)
  end

  test "GE-006 should throw with missing longitude in default options", %{browser: browser} do
    # @ts-expect-error geolocation must have longitude
    error =
      case Browser.new_context(browser, geolocation: %{latitude: 10}) do
        {:ok, context} ->
          BrowserContext.close!(context)
          nil

        {:error, error} ->
          error
      end

    assert Exception.message(error) =~ "geolocation.longitude: expected float, got undefined"
  end

  test "GE-007 should use context options", %{browser: browser, server: server} do
    options = [geolocation: %{longitude: 10, latitude: 10}, permissions: ["geolocation"]]
    context = Browser.new_context!(browser, options)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    geolocation = Page.evaluate!(page, @get_current_position)
    assert geolocation == %{"latitude" => 10, "longitude" => 10}
    BrowserContext.close!(context)
  end

  test "GE-008 watchPosition should be notified", %{server: server, context_factory: context_factory} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    BrowserContext.grant_permissions!(context, ["geolocation"])
    Page.goto!(page, server.empty_page)
    {:ok, messages} = Agent.start_link(fn -> [] end)
    Page.on(page, :console, fn message -> Agent.update(messages, &(&1 ++ [ConsoleMessage.text(message)])) end)

    BrowserContext.set_geolocation!(context, %{latitude: 0, longitude: 0})

    Page.evaluate!(page, """
    () => {
      navigator.geolocation.watchPosition(pos => {
        const coords = pos.coords;
        console.log(`lat=${coords.latitude} lng=${coords.longitude}`);
      }, err => {});
    }
    """)

    for {lat, lng} <- [{0, 10}, {20, 30}, {40, 50}] do
      text = "lat=#{lat} lng=#{lng}"

      Page.expect_console_message!(
        page,
        fn -> BrowserContext.set_geolocation!(context, %{latitude: lat, longitude: lng}) end,
        predicate: &String.contains?(ConsoleMessage.text(&1), text)
      )
    end

    all_messages = Enum.join(Agent.get(messages, & &1), "|")
    assert all_messages =~ "lat=0 lng=10"
    assert all_messages =~ "lat=20 lng=30"
    assert all_messages =~ "lat=40 lng=50"
  end

  test "GE-009 should use context options for popup", %{context_factory: context_factory, server: server} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    BrowserContext.grant_permissions!(context, ["geolocation"])
    BrowserContext.set_geolocation!(context, %{longitude: 10, latitude: 10})

    popup =
      Page.expect_popup!(page, fn ->
        Page.evaluate!(page, "url => window['_popup'] = window.open(url)", server.prefix <> "/geolocation.html")
      end)

    Page.wait_for_load_state!(popup)
    geolocation = Page.evaluate!(popup, "() => window['geolocationPromise']")
    assert geolocation == %{"longitude" => 10, "latitude" => 10}
  end
end
