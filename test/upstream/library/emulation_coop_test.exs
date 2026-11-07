defmodule PlaywrightEx.Library.EmulationCoopTest do
  @upstream "tests/library/emulation-coop.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  defp setup_routes(server) do
    for {path, coop} <- [{"/plain.html", false}, {"/coop.html", true}] do
      TestServer.set_route(server, path, fn conn ->
        conn = if coop, do: Plug.Conn.put_resp_header(conn, "cross-origin-opener-policy", "same-origin"), else: conn

        conn
        |> Plug.Conn.put_resp_header("content-type", "text/html")
        |> Plug.Conn.send_resp(200, "<title>t</title><p>hello</p>")
      end)
    end
  end

  defp probe(browser, server, options, path, media \\ nil) do
    context = Browser.new_context!(browser, options)
    page = BrowserContext.new_page!(context)
    if media, do: Page.emulate_media!(page, media)
    Page.goto!(page, server.prefix <> path)

    result =
      Page.evaluate!(page, """
      () => ({
        dark: matchMedia('(prefers-color-scheme: dark)').matches,
        dpr: devicePixelRatio,
        reducedMotion: matchMedia('(prefers-reduced-motion: reduce)').matches,
        forcedColors: matchMedia('(forced-colors: active)').matches,
        contrast: matchMedia('(prefers-contrast: more)').matches,
        print: matchMedia('print').matches,
        lang: navigator.language,
        tz: Intl.DateTimeFormat().resolvedOptions().timeZone,
        ua: navigator.userAgent,
        touch: 'ontouchstart' in window,
        coarse: matchMedia('(pointer: coarse)').matches,
        viewport: [innerWidth, innerHeight],
        screen: [screen.width, screen.height],
        orientation: screen.orientation.type,
      })
      """)

    BrowserContext.close!(context)
    result
  end

  # expect.objectContaining(expected)
  defp assert_contains(actual, expected), do: assert(Map.take(actual, Map.keys(expected)) == expected)

  describe "emulation with COOP" do
    test "EM-025 should preserve context options", %{browser: browser, server: server} do
      setup_routes(server)

      options = [
        color_scheme: :dark,
        device_scale_factor: 2,
        reduced_motion: :reduce,
        contrast: :more,
        locale: "de-DE",
        timezone_id: "Asia/Tokyo",
        user_agent: "MyUA",
        has_touch: true,
        viewport: %{width: 500, height: 600}
      ]

      plain = probe(browser, server, options, "/plain.html")

      assert_contains(plain, %{
        "dark" => true,
        "dpr" => 2,
        "reducedMotion" => true,
        "contrast" => true,
        "lang" => "de-DE",
        "tz" => "Asia/Tokyo",
        "ua" => "MyUA",
        "touch" => true,
        "viewport" => [500, 600]
      })

      coop = probe(browser, server, options, "/coop.html")
      assert coop == plain
    end

    test "EM-026 should preserve page.emulateMedia", %{browser: browser, server: server} do
      setup_routes(server)
      media = [media: :print, color_scheme: :dark, reduced_motion: :reduce, contrast: :more, forced_colors: :active]
      plain = probe(browser, server, [], "/plain.html", media)

      assert_contains(plain, %{
        "print" => true,
        "reducedMotion" => true,
        "contrast" => true,
        "forcedColors" => true
      })

      coop = probe(browser, server, [], "/coop.html", media)
      assert coop == plain
    end

    test "EM-027 should preserve mobile emulation", %{browser: browser, server: server} do
      setup_routes(server)

      options = [
        is_mobile: true,
        has_touch: true,
        viewport: %{width: 500, height: 600},
        screen: %{width: 700, height: 900}
      ]

      plain = probe(browser, server, options, "/plain.html")

      assert_contains(plain, %{
        "coarse" => true,
        "orientation" => "portrait-primary"
      })

      coop = probe(browser, server, options, "/coop.html")
      assert coop == plain
    end
  end
end
