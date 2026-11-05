defmodule PlaywrightEx.Page.PageEmulateMediaTest do
  @upstream "tests/page/page-emulate-media.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  # expect.extend({ toMatchMedia })
  defp matches_media?(page, media_query) do
    case Page.evaluate(page, "mediaQuery => matchMedia(mediaQuery).matches", media_query) do
      {:ok, pass} -> pass
      {:error, _} -> false
    end
  end

  defp assert_matches_media(page, media_query),
    do: assert(matches_media?(page, media_query), ~s|Expected "#{media_query}" to match, but it did not|)

  defp refute_matches_media(page, media_query),
    do: refute(matches_media?(page, media_query), ~s|Expected "#{media_query}" not to match, but it did|)

  test "should emulate type @smoke", %{page: page} do
    assert Page.evaluate!(page, "() => matchMedia('screen').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('print').matches") == false
    Page.emulate_media!(page, media: :print)
    assert Page.evaluate!(page, "() => matchMedia('screen').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('print').matches") == true
    Page.emulate_media!(page, %{})
    assert Page.evaluate!(page, "() => matchMedia('screen').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('print').matches") == true
    Page.emulate_media!(page, media: :null)
    assert Page.evaluate!(page, "() => matchMedia('screen').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('print').matches") == false
  end

  test "should throw in case of bad media argument", %{page: page} do
    # @ts-expect-error 'bad' is not a valid media type: passed as the wire string.
    {:error, error} = Page.emulate_media(page, media: "bad")
    assert Exception.message(error) =~ "media: expected one of (screen|print|no-override)"
  end

  test "should emulate colorScheme should work @smoke", %{page: page} do
    Page.emulate_media!(page, color_scheme: :light)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == false
    Page.emulate_media!(page, color_scheme: :dark)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches") == false
  end

  # The defaults (colorScheme 'light') pass; `colorScheme: null` is 'no-override', and WebKit on
  # macOS then follows the system appearance: dark on a dark host (macOS 26, 2026-11-05).
  @tag skip:
         if(@browser_name == "webkit" and match?({:unix, :darwin}, :os.type()),
           do: "env: WebKit on macOS follows the system appearance for colorScheme null (fails on dark hosts)"
         )
  test "should default to light", %{page: page} do
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == false

    Page.emulate_media!(page, color_scheme: :dark)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches") == false

    Page.emulate_media!(page, color_scheme: :null)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: light)').matches") == true
  end

  test "should throw in case of bad colorScheme argument", %{page: page} do
    # @ts-expect-error 'bad' is not a valid media type: passed as the wire string.
    {:error, error} = Page.emulate_media(page, color_scheme: "bad")
    assert Exception.message(error) =~ "colorScheme: expected one of (dark|light|no-preference|no-override)"
  end

  test "should work during navigation", %{page: page, server: server} do
    Page.emulate_media!(page, color_scheme: :light)
    navigated = Task.async(fn -> Page.goto!(page, server.empty_page) end)

    for i <- 0..8 do
      emulated =
        Task.async(fn -> Page.emulate_media!(page, color_scheme: Enum.at([:dark, :light], Bitwise.band(i, 1))) end)

      Process.sleep(1)
      Task.await(emulated, :infinity)
    end

    Task.await(navigated, :infinity)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-color-scheme: dark)').matches") == true
  end

  test "should change the actual colors in css", %{page: page} do
    Page.set_content!(page, """
      <style>
        @media (prefers-color-scheme: dark) {
          div {
            background: black;
            color: white;
          }
        }
        @media (prefers-color-scheme: light) {
          div {
            background: white;
            color: black;
          }
        }

      </style>
      <div>Hello</div>
    """)

    get_background_color = fn ->
      Page.eval_on_selector!(page, "div", "div => window.getComputedStyle(div).backgroundColor")
    end

    Page.emulate_media!(page, color_scheme: :light)
    assert get_background_color.() == "rgb(255, 255, 255)"

    Page.emulate_media!(page, color_scheme: :dark)
    assert get_background_color.() == "rgb(0, 0, 0)"

    Page.emulate_media!(page, color_scheme: :light)
    assert get_background_color.() == "rgb(255, 255, 255)"
  end

  test "should emulate reduced motion", %{page: page} do
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: no-preference)').matches") == true
    Page.emulate_media!(page, reduced_motion: :reduce)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: reduce)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: no-preference)').matches") == false
    Page.emulate_media!(page, reduced_motion: :no_preference)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: reduce)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: no-preference)').matches") == true
    Page.emulate_media!(page, reduced_motion: :null)
  end

  test "should keep reduced motion and color emulation after reload", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/31328' })

    # Pre-conditions
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: reduce)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: active)').matches") == false

    # Emulation
    Page.emulate_media!(page, forced_colors: :active, reduced_motion: :reduce)
    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: reduce)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: active)').matches") == true

    # Force CanonicalBrowsingContext replacement in Firefox.
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("cross-origin-opener-policy", "same-origin")
      # Note: without 'onload', Firefox sometimes does not fire the load event
      # over the protocol. The reason is unclear.
      |> Plug.Conn.send_resp(200, """
        <div>Hello there!</div>
        <script>window.onload = () => console.log('onload')</script>
      """)
    end)

    Page.goto!(page, server.empty_page)

    assert Page.evaluate!(page, "() => matchMedia('(prefers-reduced-motion: reduce)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: active)').matches") == true
  end

  test "should emulate forcedColors ", %{page: page} do
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: none)').matches") == true
    Page.emulate_media!(page, forced_colors: :none)
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: none)').matches") == true
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: active)').matches") == false
    Page.emulate_media!(page, forced_colors: :active)
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: none)').matches") == false
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: active)').matches") == true
    Page.emulate_media!(page, forced_colors: :null)
    assert Page.evaluate!(page, "() => matchMedia('(forced-colors: none)').matches") == true
  end

  test "should emulate contrast ", %{page: page} do
    assert_matches_media(page, "(prefers-contrast: no-preference)")
    Page.emulate_media!(page, contrast: :no_preference)
    assert_matches_media(page, "(prefers-contrast: no-preference)")
    refute_matches_media(page, "(prefers-contrast: more)")
    Page.emulate_media!(page, contrast: :more)
    refute_matches_media(page, "(prefers-contrast: no-preference)")
    assert_matches_media(page, "(prefers-contrast: more)")
    Page.emulate_media!(page, contrast: :null)
    assert_matches_media(page, "(prefers-contrast: no-preference)")
  end

  test "should report hover and fine pointer for desktop", %{page: page} do
    assert_matches_media(page, "(hover: hover)")
    assert_matches_media(page, "(pointer: fine)")
  end
end
