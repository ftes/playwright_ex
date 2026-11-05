defmodule PlaywrightEx.Library.ModernizrTest do
  @upstream "tests/library/modernizr.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright

  @browser_name System.get_env("BROWSER", "chromium")
  # it.skip(browserName === 'webkit' && platform === 'darwin' && os.arch() === 'x64')
  @intel_mac match?({:unix, :darwin}, :os.type()) and
               String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "x86_64")
  # it.skip(isFrozenWebkit)  -- we run the driver's own WebKit build

  defp check_features(name, context, server, asset) do
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/modernizr/index.html")
    actual = Page.evaluate!(page, "window.report")
    # JS null is `:null` in evaluate results.
    expected = "modernizr/#{name}.json" |> asset.() |> File.read!() |> JSON.decode!() |> null_to_atom()
    %{actual: actual, expected: expected}
  after
    BrowserContext.close(context)
  end

  defp null_to_atom(nil), do: :null
  defp null_to_atom(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, null_to_atom(v)} end)
  defp null_to_atom(list) when is_list(list), do: Enum.map(list, &null_to_atom/1)
  defp null_to_atom(value), do: value

  defp truthy(value), do: value not in [nil, :null, false, 0, ""]

  defp platform_overrides(expected, actual) do
    {expected, actual} =
      if match?({:unix, :linux}, :os.type()) do
        expected = Map.merge(expected, %{"speechrecognition" => false, "mediastream" => false, "todataurlwebp" => true})
        # GHA
        {Map.delete(expected, "variablefonts"), Map.delete(actual, "variablefonts")}
      else
        {expected, actual}
      end

    expected =
      if match?({:win32, _}, :os.type()) do
        expected
        |> Map.merge(%{
          "getusermedia" => false,
          "peerconnection" => false,
          "speechrecognition" => false,
          "speechsynthesis" => false,
          "todataurlwebp" => true,
          "webaudio" => false,
          "gamepads" => false
        })
        |> Map.delete("datalistelem")
        |> Map.merge(%{"mediastream" => false, "mediasource" => false, "datachannel" => false})
        |> Map.update!(
          "inputtypes",
          &Map.merge(&1, %{"color" => false, "date" => false, "datetime-local" => false, "time" => false})
        )
      else
        expected
      end

    {expected, actual}
  end

  defp normalize_media(expected, actual) do
    expected =
      expected
      |> Map.delete("webglextensions")
      |> Map.merge(%{"audio" => truthy(expected["audio"]), "video" => truthy(expected["video"])})

    actual =
      actual
      |> Map.delete("webglextensions")
      |> Map.merge(%{"audio" => truthy(actual["audio"]), "video" => truthy(actual["video"])})

    {expected, actual}
  end

  @tag skip:
         (cond do
            @intel_mac and @browser_name == "webkit" ->
              "upstream skip: Modernizr uses WebGL which is not available on Intel macOS"

            @browser_name != "webkit" ->
              "upstream skip: webkit only"

            true ->
              nil
          end)
  test "Safari Desktop", %{browser: browser, https_server: https_server, asset: asset} do
    context = Browser.new_context!(browser, device_scale_factor: 2, ignore_https_errors: true)
    %{actual: actual, expected: expected} = check_features("safari-26", context, https_server, asset)

    # Shipping Safari exposes `font-display` as a settable CSS property, open-source WebKit does not.
    expected = Map.put(expected, "fontdisplay", false)

    {expected, actual} = normalize_media(expected, actual)
    {expected, actual} = platform_overrides(expected, actual)

    # env: Linux WebKit supports <input type=month>, the safari-26 report does not (upstream client
    # too). Deviation: an override for that one key, not a skip of the test.
    expected =
      if match?({:unix, :linux}, :os.type()),
        do: put_in(expected, ["inputtypes", "month"], true),
        else: expected

    assert actual == expected
  end

  @tag skip:
         (cond do
            @intel_mac and @browser_name == "webkit" ->
              "upstream skip: Modernizr uses WebGL which is not available on Intel macOS"

            @browser_name != "webkit" ->
              "upstream skip: webkit only"

            true ->
              nil
          end)
  test "Mobile Safari", %{playwright: playwright, browser: browser, https_server: https_server, asset: asset} do
    iphone = Playwright.devices(playwright)["iPhone 12"]
    context = Browser.new_context!(browser, Map.to_list(iphone) ++ [ignore_https_errors: true])
    %{actual: actual, expected: expected} = check_features("mobile-safari-26", context, https_server, asset)

    # All platforms.
    expected =
      Map.merge(expected, %{
        "capture" => false,
        "cssscrollbar" => true,
        "cssvhunit" => true,
        "cssvmaxunit" => true,
        "overflowscrolling" => false,
        "mediasource" => true,
        "scrolltooptions" => false,
        # Shipping Safari exposes `font-display` as a settable CSS property, open-source WebKit does not.
        "fontdisplay" => false
      })

    {expected, actual} = normalize_media(expected, actual)
    {expected, actual} = platform_overrides(expected, actual)

    assert actual == expected
  end
end
