defmodule PlaywrightEx.Page.PageClickScrollTest do
  @upstream "tests/page/page-click-scroll.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  test "CL-094 should not hit scroll bar", %{page: page} do
    Page.set_content!(page, """
    <style>
      .categories { width: 180px; display: flex; overflow-x: scroll; }
      button { flex: none; height: 28px; }
    </style>
    <div class="categories">
      <button>One</button>
      <button>Two</button>
      <button>Three</button>
      <button>Story</button>
      <button>More</button>
      <button>Items</button>
      <button>Here</button>
    </div>
    """)

    Page.click!(page, "text=Story", timeout: 2000)
  end

  @tag skip:
         if(@browser_name == "chromium" and @browser_major_version < 105,
           do: "upstream skip: Needs https://chromium-review.googlesource.com/c/chromium/src/+/3758670"
         )
  test "CL-095 should scroll into view display:contents", %{page: page} do
    Page.set_content!(page, """
    <div style="background:red;height:2000px">filler</div>
    <div>
      Example text, and button here:
      <button style="display: contents" onclick="window._clicked=true;">click me</button>
    </div>
    """)

    Page.click!(page, "text=click me", timeout: 5000)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  @tag skip:
         if(@browser_name == "chromium" and @browser_major_version < 105,
           do: "upstream skip: Needs https://chromium-review.googlesource.com/c/chromium/src/+/3758670"
         )
  test "CL-096 should scroll into view display:contents with a child",
       %{page: page} do
    Page.set_content!(page, """
    <div style="background:red;height:2000px">filler</div>
    Example text, and button here:
    <button style="display: contents" onclick="window._clicked=true;"><div>click me</div></button>
    """)

    Page.click!(page, "text=click me", timeout: 5000)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  # it.fixme(browserName === 'chromium', 'DOM.getBoxModel does not work for display:contents');
  @tag skip: if(@browser_name == "chromium", do: "upstream fixme: chromium")
  test "CL-097 should scroll into view display:contents with position", %{page: page} do
    Page.set_content!(page, """
    <div style="background:red;height:2000px">filler</div>
    <div>
      Example text, and button here:
      <button style="display: contents" onclick="window._clicked=true;">click me</button>
    </div>
    """)

    Page.click!(page, "text=click me", position: %{x: 5, y: 5}, timeout: 5000)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  # issue: https://github.com/microsoft/playwright/issues/18183
  test "CL-098 should not crash when force-clicking hidden input", %{page: page} do
    Page.set_content!(page, "<input type=hidden>")
    {:error, error} = page |> Page.locator("input") |> Locator.click(force: true, timeout: 2000)
    assert Exception.message(error) =~ "Element is not visible"
  end

  # issue: https://github.com/microsoft/playwright/issues/20165
  # it.fixme(isAndroid);  -- not Android
  test "CL-099 should scroll into view span element", %{page: page} do
    Page.set_content!(page, """
    <div id=big style="height: 10000px;"></div>
    <span id=small>foo</span>
    """)

    page |> Page.locator("#small") |> Locator.scroll_into_view_if_needed!()
    assert Page.evaluate!(page, "() => window.scrollY") > 9000
  end

  # issue: https://github.com/microsoft/playwright/issues/27196
  # it.fixme(isAndroid);  -- not Android
  test "CL-100 should scroll into view element in iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <div id=big style="height: 10000px;"></div>
    <iframe src='#{server.cross_process_prefix}/input/button.html'></iframe>
    """)

    page |> Page.frame_locator("iframe") |> FrameLocator.get_by_role(:button) |> Locator.click!(timeout: 5000)
  end

  # issue: https://github.com/microsoft/playwright/issues/41421
  test "CL-101 should not scroll the page when scroll is \"none\"", %{page: page} do
    Page.set_content!(page, """
    <div style="height: 2000px;"></div>
    <button onclick="window._clicked=true">click me</button>
    """)

    {:error, error} = page |> Page.locator("button") |> Locator.click(scroll: :none, timeout: 2000)
    assert Exception.message(error) =~ "element is outside of the viewport"
    Utils.assert_falsy(Page.evaluate!(page, "window._clicked"))
    assert Page.evaluate!(page, "() => window.scrollY") == 0
  end

  test "CL-102 should click in-viewport element when scroll is \"none\"", %{page: page} do
    Page.set_content!(page, """
    <button onclick="window._clicked=true">click me</button>
    <div style="height: 2000px;"></div>
    """)

    page |> Page.locator("button") |> Locator.click!(scroll: :none, timeout: 2000)
    assert Page.evaluate!(page, "window._clicked") == true
    assert Page.evaluate!(page, "() => window.scrollY") == 0
  end

  # issue: https://github.com/microsoft/playwright/issues/41421
  test "CL-103 should not scroll nested container when scroll is \"none\"", %{page: page} do
    Page.set_content!(page, """
    <div style="height: 100px; width: 100px; overflow-y: scroll;">
      <div style="height: 50px;">A</div>
      <div style="height: 50px;">B</div>
      <button style="height: 50px; width: 100px;" onclick="window._clicked=true">C</button>
    </div>
    """)

    button = Page.locator(page, "button")
    # The button is scrolled out of the nested overflow container.
    {:error, error} = Locator.click(button, scroll: :none, timeout: 2000)
    assert error
    Utils.assert_falsy(Page.evaluate!(page, "window._clicked"))
    # Default behavior scrolls the nested container into view and succeeds.
    Locator.click!(button, timeout: 2000)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "CL-104 should not scroll on hover when scroll is \"none\"", %{page: page} do
    Page.set_content!(page, """
    <div style="height: 2000px;"></div>
    <div onmouseover="window._hovered=true" style="width: 50px; height: 50px;">hover me</div>
    """)

    {:error, error} = page |> Page.locator("div >> text=hover me") |> Locator.hover(scroll: :none, timeout: 2000)
    assert Exception.message(error) =~ "element is outside of the viewport"
    Utils.assert_falsy(Page.evaluate!(page, "window._hovered"))
    assert Page.evaluate!(page, "() => window.scrollY") == 0
  end

  # issue: https://github.com/microsoft/playwright/issues/42625
  test "CL-105 should scroll instantly on retry when scroll-behavior is smooth", %{page: page} do
    # The fixed header covers everything but the bottom strip of the viewport.
    # The first attempt centers the button under the header, so the click is
    # retried with a different scroll alignment using the native scrollIntoView().
    Page.set_content!(page, """
    <style>
      html { scroll-behavior: smooth; }
      body { margin: 0; }
      .spacer { height: 2000px; }
      #header { position: fixed; top: 0; left: 0; right: 0; bottom: 50px; background: rgba(0, 0, 0, 0.1); }
      button { height: 30px; }
    </style>
    <div id="header"></div>
    <div class="spacer"></div>
    <button onclick="window.clicked = true">Target</button>
    <div class="spacer"></div>
    <script>
      window.scrolls = [];
      addEventListener('scroll', () => window.scrolls.push(window.scrollY));
    </script>
    """)

    Page.click!(page, "button")
    assert Page.evaluate!(page, "window.clicked") == true
    # Every scroll performed by Playwright should be a single instant jump,
    # and never a smooth animation that fires a scroll event per frame.
    scrolls = Page.evaluate!(page, "() => window['scrolls']")
    assert length(scrolls) <= 2
  end
end
