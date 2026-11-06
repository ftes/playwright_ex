defmodule PlaywrightEx.Library.ScreencastOverlayTest do
  @upstream "tests/library/screencast-overlay.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import Bitwise

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Screencast
  alias PlaywrightEx.Utils

  # test.skip(({ mode }) => mode !== 'default', 'Overlay uses an open shadow root only in default mode');  -- always default mode

  # `PNG.sync.read(screenshot)` (pngjs): a minimal decoder for the 8-bit, non-interlaced RGB(A)
  # PNGs the browsers produce.
  defp pixel(screenshot, x, y) do
    <<137, 80, 78, 71, 13, 10, 26, 10, chunks::binary>> = screenshot
    {%{width: width, bpp: bpp}, idat} = png_chunks(chunks, nil, [])

    row =
      unfilter_rows(:zlib.uncompress(IO.iodata_to_binary(idat)), width * bpp, bpp, y, :binary.copy(<<0>>, width * bpp))

    offset = x * bpp
    <<_::binary-size(^offset), r, g, b, _::binary>> = row
    [r, g, b]
  end

  defp png_chunks(<<len::32, type::binary-4, data::binary-size(len), _crc::32, rest::binary>>, header, idat) do
    case type do
      "IHDR" ->
        <<width::32, _height::32, 8, color_type, _compression, _filter, 0>> = data
        png_chunks(rest, %{width: width, bpp: if(color_type == 6, do: 4, else: 3)}, idat)

      "IDAT" ->
        png_chunks(rest, header, [idat, data])

      "IEND" ->
        {header, idat}

      _ ->
        png_chunks(rest, header, idat)
    end
  end

  defp unfilter_rows(data, stride, bpp, y, prev) do
    <<filter, line::binary-size(^stride), rest::binary>> = data
    row = unfilter(filter, :binary.bin_to_list(line), List.to_tuple(:binary.bin_to_list(prev)), bpp)
    if y == 0, do: row, else: unfilter_rows(rest, stride, bpp, y - 1, row)
  end

  defp unfilter(filter, line, prev, bpp) do
    {reversed, _} =
      Enum.reduce(line, {[], 0}, fn x, {acc, i} ->
        a = if i >= bpp, do: Enum.at(acc, bpp - 1), else: 0
        b = elem(prev, i)
        c = if i >= bpp, do: elem(prev, i - bpp), else: 0

        value =
          case filter do
            0 -> x
            1 -> x + a
            2 -> x + b
            3 -> x + div(a + b, 2)
            4 -> x + paeth(a, b, c)
          end

        {[band(value, 255) | acc], i + 1}
      end)

    reversed |> Enum.reverse() |> :binary.list_to_bin()
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

  test "should add and remove overlay", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    disposable = Screencast.show_overlay!(Page.screencast(page), ~s(<div id="my-overlay">Hello Overlay</div>))
    Expect.to_be_visible!(Page.locator(page, "x-pw-user-overlays"))
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 1)
    Expect.to_have_text!(Page.locator(page, "#my-overlay"), "Hello Overlay")

    Disposable.dispose!(disposable)
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 0)

    BrowserContext.close!(context)
  end

  test "should add multiple overlays", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    d1 = Screencast.show_overlay!(Page.screencast(page), ~s(<div id="overlay-1">First</div>))
    d2 = Screencast.show_overlay!(Page.screencast(page), ~s(<div id="overlay-2">Second</div>))
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 2)
    Expect.to_have_text!(Page.locator(page, "#overlay-1"), "First")
    Expect.to_have_text!(Page.locator(page, "#overlay-2"), "Second")

    Disposable.dispose!(d1)
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 1)
    Expect.to_have_text!(Page.locator(page, "#overlay-2"), "Second")

    Disposable.dispose!(d2)
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 0)

    BrowserContext.close!(context)
  end

  test "should hide and show overlays", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Screencast.show_overlay!(Page.screencast(page), ~s(<div id="my-overlay">Visible</div>))
    Expect.to_be_visible!(Page.locator(page, "x-pw-user-overlays"))

    Screencast.hide_overlays!(Page.screencast(page))
    Expect.to_be_hidden!(Page.locator(page, "x-pw-user-overlays"))

    Screencast.show_overlays!(Page.screencast(page))
    Expect.to_be_visible!(Page.locator(page, "x-pw-user-overlays"))
    Expect.to_have_text!(Page.locator(page, "#my-overlay"), "Visible")

    BrowserContext.close!(context)
  end

  test "should survive navigation", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Screencast.show_overlay!(Page.screencast(page), ~s(<div id="persistent">Survives Reload</div>))
    Expect.to_have_text!(Page.locator(page, "#persistent"), "Survives Reload")

    Page.goto!(page, server.empty_page)
    Expect.to_have_text!(Page.locator(page, "#persistent"), "Survives Reload")

    Page.reload!(page)
    Expect.to_have_text!(Page.locator(page, "#persistent"), "Survives Reload")

    BrowserContext.close!(context)
  end

  test "should remove overlay and not restore after navigation", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    disposable = Screencast.show_overlay!(Page.screencast(page), ~s(<div id="temp">Temporary</div>))
    Expect.to_have_text!(Page.locator(page, "#temp"), "Temporary")

    Disposable.dispose!(disposable)
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 0)

    Page.reload!(page)
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 0)

    BrowserContext.close!(context)
  end

  test "should sanitize scripts from overlay html", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Screencast.show_overlay!(
      Page.screencast(page),
      ~s(<div id="safe">Safe</div><script>window.__injected = true</script>)
    )

    Expect.to_have_text!(Page.locator(page, "#safe"), "Safe")
    assert Page.evaluate!(page, "() => window.__injected") == nil

    BrowserContext.close!(context)
  end

  test "should strip event handlers from overlay html", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Screencast.show_overlay!(
      Page.screencast(page),
      ~s(<div id="clean" onclick="window.__clicked=true">Click me</div>)
    )

    Expect.to_have_text!(Page.locator(page, "#clean"), "Click me")
    has_onclick = page |> Page.locator("#clean") |> Locator.evaluate!("el => el.hasAttribute('onclick')")
    assert has_onclick == false

    BrowserContext.close!(context)
  end

  test "should auto-remove overlay after timeout", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Screencast.show_overlay!(Page.screencast(page), ~s(<div id="timed">Temporary</div>), duration: 1)
    Expect.to_have_count!(Page.locator(page, ".x-pw-user-overlay"), 0)

    BrowserContext.close!(context)
  end

  test "should allow styles in overlay html", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Screencast.show_overlay!(
      Page.screencast(page),
      ~s(<div id="styled" style="color: red; font-size: 20px;">Styled</div>)
    )

    Expect.to_have_text!(Page.locator(page, "#styled"), "Styled")
    color = page |> Page.locator("#styled") |> Locator.evaluate!("el => getComputedStyle(el).color")
    assert color == "rgb(255, 0, 0)"

    BrowserContext.close!(context)
  end

  @red_overlay ~s{<div style="position: absolute; top: 50px; left: 50px; width: 200px; height: 100px; background: rgb(255, 0, 0);"></div>}

  @dialog_page """
    <dialog id="target" style="position: fixed; inset: 0; margin: 0; width: 100vw; height: 100vh; padding: 0; border: 0; background: rgb(200, 200, 200);"></dialog>
    <button onclick="target.showModal()">Open</button>
  """
  @popover_page """
    <div id="target" popover="manual" style="inset: 0; margin: 0; width: 100%; height: 100%; max-width: none; max-height: none; padding: 0; border: 0; background: rgb(200, 200, 200);"></div>
    <button onclick="target.showPopover()">Open</button>
  """
  @top_layer_pages [dialog: @dialog_page, popover: @popover_page]

  for {kind, content} <- @top_layer_pages do
    @content content

    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42629' }
    test "should show overlay above #{kind} opened before it", %{browser: browser} do
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      Page.set_content!(page, @content)
      disposable = Screencast.show_overlay!(Page.screencast(page), "<div></div>")
      Disposable.dispose!(disposable)

      page |> Page.get_by_role("button", name: "Open") |> Locator.click!()
      assert pixel(Page.screenshot!(page), 100, 100) == [200, 200, 200]

      Screencast.show_overlay!(Page.screencast(page), @red_overlay)
      assert pixel(Page.screenshot!(page), 100, 100) == [255, 0, 0]

      BrowserContext.close!(context)
    end

    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/42629' }
    test "should keep overlay above #{kind} opened after it", %{browser: browser} do
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      Page.set_content!(page, @content)
      Screencast.show_overlay!(Page.screencast(page), @red_overlay)
      assert pixel(Page.screenshot!(page), 100, 100) == [255, 0, 0]

      page |> Page.get_by_role("button", name: "Open") |> Locator.click!()
      Utils.poll(fn -> pixel(Page.screenshot!(page), 100, 100) end, &assert(&1 == [255, 0, 0]))

      BrowserContext.close!(context)
    end
  end
end
