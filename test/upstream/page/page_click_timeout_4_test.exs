defmodule PlaywrightEx.Page.PageClickTimeout4Test do
  @upstream "tests/page/page-click-timeout-4.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [rafraf: 1]

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should timeout waiting for stable position", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")

    JSHandle.evaluate!(button, """
    button => {
      button.style.transition = 'margin 5s linear 0s';
      button.style.marginLeft = '200px';
    }
    """)

    # rafraf for Firefox to kick in the animation.
    rafraf(page)
    {:error, error} = ElementHandle.click(button, timeout: 3000)
    assert Exception.message(error) =~ "elementHandle.click: Timeout 3000ms exceeded."
    assert Exception.message(error) =~ "waiting for element to be visible, enabled and stable"
    assert Exception.message(error) =~ "element is not stable"
    assert Exception.message(error) =~ "retrying click action"
  end

  test "should click for the second time after first timeout"

  test "should fail to click the button behind a large header after scrolling around", %{page: page} do
    # it.skip(isAndroid, 'Different viewport size');
    Page.set_viewport_size!(page, %{width: 500, height: 240})

    Page.set_content!(page, """
      <style>
      * {
        padding: 0;
        margin: 0;
      }
      li {
        height: 80px;
        border: 1px solid black;
      }
      ol {
        padding-top: 160px;
      }
      div.fixed {
        position: fixed;
        z-index: 1001;
        width: 100%;
        background: rgba(255, 0, 0, 0.2);
        height: 2000px;
      }
      </style>

      <div class=fixed></div>

      <ol>
      <li>hi1</li><li>hi2</li><li>hi3</li><li>hi4</li><li>hi5</li><li>hi6</li><li>hi7</li><li>hi8</li>
      <li id=target onclick="window.__clicked = true">hi9</li>
      <li>hi10</li><li>hi11</li><li>hi12</li><li>hi13</li><li id=li14>hi14</li>
      </ol>

      <script>
        window.scrollTops = [];
        window.addEventListener('scroll', () => {
          window.scrollTops.push(window.scrollY);
        });
      </script>
    """)

    Page.eval_on_selector!(page, "#li14", "e => e.scrollIntoView()")
    {:error, error} = Page.click(page, "#target", timeout: 3500)
    assert Exception.message(error) =~ ~s(<div class="fixed"></div> intercepts pointer events)
    assert Page.evaluate!(page, "() => window['__clicked']") == nil
    scroll_tops = Page.evaluate!(page, "() => window['scrollTops']")
    distinct = MapSet.new(scroll_tops)
    # At least three different scroll positions.
    assert MapSet.size(distinct) > 2
  end
end
