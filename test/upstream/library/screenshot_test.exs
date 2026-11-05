defmodule PlaywrightEx.Library.ScreenshotTest do
  @upstream "tests/library/screenshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  # PNG.sync.read (pngjs): enough of a decoder for the browsers' screenshots (8-bit, not
  # interlaced, RGB or RGBA).
  defp decode_png(<<137, "PNG", 13, 10, 26, 10, chunks::binary>>), do: decode_chunks(chunks, %{idat: []})

  defp decode_chunks(<<length::32, type::binary-4, data::binary-size(length), _crc::32, rest::binary>>, png) do
    case type do
      "IHDR" ->
        <<width::32, height::32, 8, color_type, _compression, _filter, 0>> = data
        decode_chunks(rest, Map.merge(png, %{width: width, height: height, color_type: color_type}))

      "IDAT" ->
        decode_chunks(rest, %{png | idat: [png.idat | data]})

      "IEND" ->
        png |> Map.put(:data, :zlib.uncompress(png.idat)) |> Map.delete(:idat)

      _ ->
        decode_chunks(rest, png)
    end
  end

  # PNG.bitblt of one pixel. Filters only look left and up, so unfiltering the first `x + 1`
  # pixels of rows `0..y` is enough.
  defp pixel(%{width: width, color_type: color_type, data: data}, x, y) do
    bpp = %{2 => 3, 6 => 4}[color_type]
    stride = 1 + width * bpp
    prefix = (x + 1) * bpp

    row =
      Enum.reduce(0..y, :binary.copy(<<0>>, prefix), fn row, prev ->
        <<filter, line::binary-size(^prefix), _::binary>> = binary_part(data, row * stride, stride)
        unfilter(filter, line, prev, bpp)
      end)

    <<r, g, b, rest::binary>> = binary_part(row, x * bpp, bpp)
    %{r: r, g: g, b: b, a: if(rest == "", do: 255, else: :binary.first(rest))}
  end

  defp unfilter(filter, line, prev, bpp) do
    line
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.reduce(<<>>, fn {byte, i}, cur ->
      a = if i >= bpp, do: :binary.at(cur, i - bpp), else: 0
      b = :binary.at(prev, i)
      c = if i >= bpp, do: :binary.at(prev, i - bpp), else: 0

      predictor =
        case filter do
          0 -> 0
          1 -> a
          2 -> b
          3 -> div(a + b, 2)
          4 -> paeth(a, b, c)
        end

      <<cur::binary, rem(byte + predictor, 256)>>
    end)
  end

  defp paeth(a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  defp body_size(page),
    do: Page.evaluate!(page, "() => ({ width: document.body.offsetWidth, height: document.body.offsetHeight })")

  describe "page screenshot" do
    # browserTest.skip(browserName === 'firefox' && !headless)  -- we run headless

    @tag skip: "not ported: toMatchSnapshot"
    test "should run in parallel in multiple pages"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with a mobile viewport"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with a mobile viewport and clip"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with a mobile viewport and fullPage"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with device scale factor"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with device scale factor and clip"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with device scale factor and scale:css"

    test "should produce screenshot of correct size with scale:css and null viewport", %{
      browser: browser,
      server: server
    } do
      context = Browser.new_context!(browser, viewport: :null)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/grid.html")
      [inner_width, inner_height] = Page.evaluate!(page, "() => [window.innerWidth, window.innerHeight]")
      screenshot = Page.screenshot!(page, scale: :css)
      decoded = decode_png(screenshot)
      assert decoded.width == inner_width
      assert decoded.height == inner_height
      BrowserContext.close!(context)
    end

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with device scale factor, clip and scale:css"

    test "should throw if screenshot size is too large with device scale factor", %{
      browser: browser,
      browser_name: browser_name
    } do
      # annotation: https://github.com/microsoft/playwright/issues/16727
      is_mac = match?({:unix, :darwin}, :os.type())
      context = Browser.new_context!(browser, viewport: %{width: 500, height: 500}, device_scale_factor: 2)
      page = BrowserContext.new_page!(context)

      Page.set_content!(
        page,
        "<style>body {margin: 0; padding: 0;}</style><div style='min-height: 16383px; background: red;'></div>"
      )

      result = Page.screenshot!(page, full_page: true)
      assert result

      Page.set_content!(
        page,
        "<style>body {margin: 0; padding: 0;}</style><div style='min-height: 16384px; background: red;'></div>"
      )

      exception = Page.screenshot(page, full_page: true)

      # (browserName === 'firefox' && !isBidi): we run Juggler firefox, never BiDi
      if browser_name == "firefox" or (browser_name == "webkit" and not is_mac) do
        {:error, error} = exception
        assert Exception.message(error) =~ "Cannot take screenshot larger than 32767"
      end

      image = Page.screenshot!(page, full_page: true, scale: :css)
      assert image
      BrowserContext.close!(context)
    end

    # annotation: https://github.com/microsoft/playwright/issues/4038
    # browserTest.fixme(chromium && !headless && linux)  -- we run headless
    test "should work with large size", %{context_factory: context_factory} do
      context = context_factory.([])
      page = BrowserContext.new_page!(context)

      Page.set_viewport_size!(page, %{width: 1280, height: 800})

      Page.evaluate!(page, """
      () => {
        document.body.style.margin = '0';
        document.body.style.padding = '0';
        document.documentElement.style.margin = '0';
        document.documentElement.style.padding = '0';
        const div = document.createElement('div');
        div.style.width = '1250px';
        div.style.height = '8440px';
        div.style.background = 'linear-gradient(red, blue)';
        document.body.appendChild(div);
      }
      """)

      buffer = Page.screenshot!(page, full_page: true)
      decoded = decode_png(buffer)

      assert pixel(decoded, 0, 0).r > 128
      assert pixel(decoded, 0, 0).b < 128
      assert pixel(decoded, 0, 8339).r < 128
      assert pixel(decoded, 0, 8339).b > 128
    end

    test "should handle vh units ", %{context_factory: context_factory} do
      context = context_factory.([])
      page = BrowserContext.new_page!(context)

      Page.set_viewport_size!(page, %{width: 800, height: 500})

      Page.evaluate!(page, """
      () => {
        document.body.style.margin = '0';
        document.body.style.padding = '0';
        document.documentElement.style.margin = '0';
        document.documentElement.style.padding = '0';
        const div = document.createElement('div');
        div.style.width = '100%';
        div.style.borderTop = '100vh solid red';
        div.style.borderBottom = '100vh solid blue';
        document.body.appendChild(div);
      }
      """)

      buffer = Page.screenshot!(page, full_page: true)
      decoded = decode_png(buffer)

      assert pixel(decoded, 0, 0).r > 128
      assert pixel(decoded, 0, 0).b < 128
      assert pixel(decoded, 0, 999).r < 128
      assert pixel(decoded, 0, 999).b > 128
    end

    # browserTest.skip(mode === 'driver', 'test hooks are not available in driver mode')
    @tag skip: "not ported: __testHookBeforeScreenshot (JS-only test hook)"
    test "should not hang when event loop is blocked"
  end

  describe "element screenshot" do
    # browserTest.skip(browserName === 'firefox' && !headless)  -- we run headless

    @tag skip: "not ported: toMatchSnapshot"
    test "element screenshot should work with a mobile viewport"

    @tag skip: "not ported: toMatchSnapshot"
    test "element screenshot should work with device scale factor"

    test "should take screenshots when default viewport is null", %{browser: browser} do
      context = Browser.new_context!(browser, viewport: :null)
      page = BrowserContext.new_page!(context)
      Page.set_content!(page, "<div style='height: 10000px; background: red'></div>")

      window_size =
        Page.evaluate!(
          page,
          "() => ({ width: window.innerWidth * window.devicePixelRatio, height: window.innerHeight * window.devicePixelRatio })"
        )

      size_before = body_size(page)

      screenshot = Page.screenshot!(page)
      assert is_binary(screenshot)
      decoded = decode_png(screenshot)
      assert decoded.width == window_size["width"]
      assert decoded.height == window_size["height"]

      size_after = body_size(page)
      assert size_before["width"] == size_after["width"]
      assert size_before["height"] == size_after["height"]
      BrowserContext.close!(context)
    end

    test "should take fullPage screenshots when default viewport is null", %{server: server, browser: browser} do
      context = Browser.new_context!(browser, viewport: :null)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/grid.html")
      size_before = body_size(page)
      screenshot = Page.screenshot!(page, full_page: true)
      assert is_binary(screenshot)

      size_after = body_size(page)
      assert size_before["width"] == size_after["width"]
      assert size_before["height"] == size_after["height"]
      BrowserContext.close!(context)
    end

    test "should restore default viewport after fullPage screenshot", %{browser: browser} do
      context = Browser.new_context!(browser, viewport: %{width: 456, height: 789})
      page = BrowserContext.new_page!(context)
      Utils.verify_viewport(page, 456, 789)
      screenshot = Page.screenshot!(page, full_page: true)
      assert is_binary(screenshot)
      Utils.verify_viewport(page, 456, 789)
      BrowserContext.close!(context)
    end

    @tag skip: "not ported: __testHookBeforeScreenshot (JS-only test hook)"
    test "should restore viewport after page screenshot and exception"

    @tag skip: "not ported: __testHookAfterScreenshot (JS-only test hook)"
    test "should restore viewport after page screenshot and timeout"

    test "should take element screenshot when default viewport is null and restore back", %{browser: browser} do
      context = Browser.new_context!(browser, viewport: :null)
      page = BrowserContext.new_page!(context)

      Page.set_content!(page, """
        <div style="height: 14px">oooo</div>
        <style>
        div.to-screenshot {
          border: 1px solid blue;
          width: 600px;
          height: 600px;
          margin-left: 50px;
        }
        ::-webkit-scrollbar{
          display: none;
        }
        </style>
        <div class="to-screenshot"></div>
        <div class="to-screenshot"></div>
        <div class="to-screenshot"></div>
      """)

      size_before = body_size(page)
      element_handle = Page.query_selector!(page, "div.to-screenshot")
      screenshot = ElementHandle.screenshot!(element_handle)
      assert is_binary(screenshot)
      size_after = body_size(page)
      assert size_before["width"] == size_after["width"]
      assert size_before["height"] == size_after["height"]
      BrowserContext.close!(context)
    end

    @tag skip: "not ported: __testHookBeforeScreenshot (JS-only test hook)"
    test "should restore viewport after element screenshot and exception"

    test "element screenshots should handle vh units ", %{context_factory: context_factory} do
      context = context_factory.([])
      page = BrowserContext.new_page!(context)

      Page.set_viewport_size!(page, %{width: 800, height: 500})

      Page.evaluate!(page, """
      () => {
        const div = document.createElement('div');
        div.style.width = '100%';
        div.style.borderTop = '100vh solid red';
        div.style.borderBottom = '100vh solid blue';
        document.body.appendChild(div);
      }
      """)

      element_handle = Page.query_selector!(page, "div")
      buffer = ElementHandle.screenshot!(element_handle)
      decoded = decode_png(buffer)

      assert pixel(decoded, 0, 0).r > 128
      assert pixel(decoded, 0, 0).b < 128
      assert pixel(decoded, 0, 999).r < 128
      assert pixel(decoded, 0, 999).b > 128
    end

    @tag skip: "not ported: toMatchSnapshot"
    test "should work if the main resource hangs"

    @tag skip: "not ported: toMatchSnapshot"
    test "should capture full element when larger than viewport with device scale factor"

    @tag skip: "not ported: toMatchSnapshot"
    test "should capture full element when larger than viewport with device scale factor and scale:css"

    # annotation: https://github.com/microsoft/playwright/issues/26447
    if System.get_env("BROWSER") == "webkit", do: @tag(skip: "upstream fixme: webkit")

    @tag :tmp_dir
    test "page screenshot should capture css transform with device pixels", %{
      browser: browser,
      browser_name: browser_name,
      tmp_dir: tmp_dir
    } do
      context = Browser.new_context!(browser, viewport: %{width: 500, height: 500}, device_scale_factor: 3)
      page = BrowserContext.new_page!(context)

      Page.set_content!(page, """
        <style>
        .container {
          width: 150px;
          height: 150px;
          margin: 75px 0 0 75px;
          border: none;
        }

        .cube {
          width: 100%;
          height: 100%;
          perspective: 550px;
          perspective-origin: 150% 150%;
        }

        .face {
          display: block;
          position: absolute;
          width: 100px;
          height: 100px;
          border: none;
        }

        .right {
          background: rgba(196, 0, 0, 0.7);
          transform: rotateY(70deg);
        }

        </style>
        <div class="container">
          <div class="cube showbf">
            <div class="face right"></div>
          </div>
        </div>
      """)

      # The runner resolves the unnamed snapshot to the spec's `<describe>-<test>-1-<project>.png`.
      path = Path.join(tmp_dir, "snapshot.png")

      File.cp!(
        Path.join(
          PlaywrightEx.Upstream.dir(),
          "tests/library/screenshot.spec.ts-snapshots/element-screenshot-page-screenshot-should-capture-css-transform-with-device-pixels-1-#{browser_name}.png"
        ),
        path
      )

      Expect.to_have_screenshot!(page, path: path, scale: :device)
      BrowserContext.close!(context)
    end
  end
end
