defmodule PlaywrightEx.Library.ScreencastActionsTest do
  @upstream "tests/library/screencast-actions.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Screencast
  alias PlaywrightEx.Utils

  # test.skip(({ mode }) => mode !== 'default', ...)  -- we run in default mode

  @style %{
    point: "width: 20px; height: 20px; border-radius: 50%; background: red",
    highlight: "outline: 2px solid #333"
  }

  # page.click(...).catch(() => {}): not awaited.
  defp click_later(page, selector, options \\ []), do: Task.start(fn -> Page.click(page, selector, options) end)

  defp new_page(browser) do
    context = Browser.new_context!(browser)
    {context, BrowserContext.new_page!(context)}
  end

  defp close_to?(a, b), do: abs(a - b) < 0.5

  test "should show annotation on click", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page), duration: 5000)
    click_later(page, "button")

    Expect.to_be_visible!(Page.locator(page, "x-pw-title"))
    Expect.to_have_text!(Page.locator(page, "x-pw-title"), ~r/click/i)
    # Point and highlight are only shown when styled.
    Expect.to_have_count!(Page.locator(page, "x-pw-screencast-highlight"), 0)
    Expect.to_have_count!(Page.locator(page, "x-pw-screencast-point"), 0)

    BrowserContext.close!(context)
  end

  test "should render annotation styles", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page),
      duration: 5000,
      font_size: 32,
      style: Map.put(@style, :title, "top: 100px; background-color: rgb(1, 2, 3)")
    )

    button_box = Locator.bounding_box!(Page.locator(page, "button"))
    click_later(page, "button")

    # Highlight: styled box that covers the target.
    highlight = Page.locator(page, "x-pw-screencast-highlight")
    Expect.to_be_visible!(highlight)
    assert Locator.evaluate!(highlight, "el => getComputedStyle(el).outlineWidth") == "2px"
    box = Locator.bounding_box!(highlight)
    assert close_to?(box.x, button_box.x)
    assert close_to?(box.y, button_box.y)
    assert close_to?(box.width, button_box.width)
    assert close_to?(box.height, button_box.height)

    # Point: styled marker centered on the click point, Firefox rounds the click point.
    point_box = Locator.bounding_box!(Page.locator(page, "x-pw-screencast-point"))
    assert point_box.width == 20
    assert abs(point_box.x + 10 - (button_box.x + button_box.width / 2)) <= 1
    assert abs(point_box.y + 10 - (button_box.y + button_box.height / 2)) <= 1

    # Title: style applies on top of deprecated fontSize, position wins over style.
    title = Page.locator(page, "x-pw-title")
    Expect.to_be_visible!(title)

    title_style =
      Locator.evaluate!(title, """
      el => {
        const cs = getComputedStyle(el);
        return {
          color: cs.color, borderRadius: cs.borderRadius, padding: cs.padding, backgroundColor: cs.backgroundColor,
          top: el.style.top, right: el.style.right, fontSize: el.style.fontSize,
        };
      }
      """)

    assert title_style["backgroundColor"] == "rgb(1, 2, 3)"
    assert title_style["color"] == "rgb(255, 255, 255)"
    assert title_style["borderRadius"] == "6px"
    assert title_style["padding"] == "6px"
    assert title_style["top"] == "6px"
    assert title_style["right"] == "6px"
    assert title_style["fontSize"] == "32px"

    BrowserContext.close!(context)
  end

  for {position, option, expected} <- [
        {"top-left", :top_left, %{"top" => "6px", "left" => "6px"}},
        {"top", :top, %{"top" => "6px", "left" => "50%"}},
        {"bottom-left", :bottom_left, %{"bottom" => "6px", "left" => "6px"}},
        {"bottom", :bottom, %{"bottom" => "6px", "left" => "50%"}},
        {"bottom-right", :bottom_right, %{"bottom" => "6px", "right" => "6px"}}
      ] do
    @option option
    @expected expected
    test "should position title at #{position}", %{browser: browser, server: server} do
      {context, page} = new_page(browser)
      Page.goto!(page, server.prefix <> "/input/button.html")

      Screencast.show_actions!(Page.screencast(page), duration: 5000, position: @option)
      click_later(page, "button")

      title = Page.locator(page, "x-pw-title")
      Expect.to_be_visible!(title)

      title_style =
        Locator.evaluate!(title, """
        el => ({
          top: el.style.top,
          bottom: el.style.bottom,
          left: el.style.left,
          right: el.style.right,
        })
        """)

      for {key, value} <- @expected, do: assert(title_style[key] == value)

      BrowserContext.close!(context)
    end
  end

  test "should clear annotation after duration", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page), duration: 1000, style: @style)
    Page.click!(page, "button")

    Expect.to_have_count!(Page.locator(page, "x-pw-screencast-point"), 0)
    Expect.to_have_count!(Page.locator(page, "x-pw-screencast-highlight"), 0)
    Expect.to_be_hidden!(Page.locator(page, "x-pw-title"))

    BrowserContext.close!(context)
  end

  test "should annotate fill action", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/textarea.html")

    Screencast.show_actions!(Page.screencast(page), duration: 5000)
    Task.start(fn -> Page.fill(page, "textarea", "hello") end)

    title = Page.locator(page, "x-pw-title")
    Expect.to_be_visible!(title)
    Expect.to_have_text!(title, ~r/fill/i)

    BrowserContext.close!(context)
  end

  test "should stop showing actions after dispose", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    actions = Screencast.show_actions!(Page.screencast(page), duration: 1000)
    Page.click!(page, "button")
    Disposable.dispose!(actions)

    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")

    Expect.to_be_hidden!(Page.locator(page, "x-pw-title"))

    BrowserContext.close!(context)
  end

  test "should stop showing actions after hideActions", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page), duration: 1000)
    Page.click!(page, "button")
    Screencast.hide_actions!(Page.screencast(page))

    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")

    Expect.to_be_hidden!(Page.locator(page, "x-pw-title"))

    BrowserContext.close!(context)
  end

  test "should render an action cursor that animates to the click point", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page), duration: 5000)
    click_later(page, "button")

    cursor = Page.locator(page, "x-pw-action-cursor")
    Expect.to_be_visible!(cursor)

    initial = Locator.evaluate!(cursor, "el => ({ top: el.style.top, left: el.style.left })")
    assert initial["top"] =~ ~r/\d+px/
    assert initial["left"] =~ ~r/\d+px/

    BrowserContext.close!(context)
  end

  test "cursor moves between two pointer actions", %{browser: browser} do
    {context, page} = new_page(browser)

    Page.set_content!(page, """
    <div style="position: fixed; top: 20px; left: 20px; width: 60px; height: 60px;" id="a">A</div>
    <div style="position: fixed; bottom: 20px; right: 20px; width: 60px; height: 60px;" id="b">B</div>
    """)

    Screencast.show_actions!(Page.screencast(page), duration: 5000)
    cursor = Page.locator(page, "x-pw-action-cursor")

    click_later(page, "#a", force: true)
    Expect.to_be_visible!(cursor)
    first = Locator.evaluate!(cursor, "el => ({ top: el.style.top, left: el.style.left })")

    click_later(page, "#b", force: true)

    Utils.poll(
      fn -> Locator.evaluate!(cursor, "el => ({ top: el.style.top, left: el.style.left })") end,
      &refute(&1 == first)
    )

    BrowserContext.close!(context)
  end

  test "cursor: \"none\" suppresses the action cursor decoration", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page), duration: 5000, cursor: :none)
    click_later(page, "button")

    # The title still renders, but the cursor does not.
    Expect.to_be_visible!(Page.locator(page, "x-pw-title"))
    Expect.to_be_hidden!(Page.locator(page, "x-pw-action-cursor"))

    BrowserContext.close!(context)
  end

  test "cursor stays at the last action point until hideActions", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page), duration: 100)
    Page.click!(page, "button")
    Expect.to_be_hidden!(Page.locator(page, "x-pw-title"))
    cursor = Page.locator(page, "x-pw-action-cursor")
    Expect.to_be_visible!(cursor)
    position = Locator.evaluate!(cursor, "el => ({ top: el.style.top, left: el.style.left })")

    Page.goto!(page, server.empty_page)
    Expect.to_be_visible!(cursor)
    assert Locator.evaluate!(cursor, "el => ({ top: el.style.top, left: el.style.left })") == position

    Screencast.hide_actions!(Page.screencast(page))
    Expect.to_be_hidden!(cursor)

    BrowserContext.close!(context)
  end

  test "should survive navigation", %{browser: browser, server: server} do
    {context, page} = new_page(browser)
    Page.goto!(page, server.prefix <> "/input/button.html")

    Screencast.show_actions!(Page.screencast(page), duration: 5000)
    click_later(page, "button")

    Expect.to_be_visible!(Page.locator(page, "x-pw-title"))

    Page.goto!(page, server.prefix <> "/input/button.html")
    click_later(page, "button")

    Expect.to_be_visible!(Page.locator(page, "x-pw-title"))

    BrowserContext.close!(context)
  end
end
