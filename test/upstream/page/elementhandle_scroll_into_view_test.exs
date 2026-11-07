defmodule PlaywrightEx.Page.ElementhandleScrollIntoViewTest do
  @upstream "tests/page/elementhandle-scroll-into-view.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime

  @moduletag :page

  test "EH-093 should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/offscreenbuttons.html")

    for i <- 0..10 do
      button = Page.query_selector!(page, "#btn#{i}")

      before =
        JSHandle.evaluate!(button, "button => { return button.getBoundingClientRect().right - window.innerWidth; }")

      assert before == 10 * i
      ElementHandle.scroll_into_view_if_needed!(button)

      after_ =
        JSHandle.evaluate!(button, "button => { return button.getBoundingClientRect().right - window.innerWidth; }")

      assert after_ <= 0 == true
      Page.evaluate!(page, "() => window.scrollTo(0, 0)")
    end
  end

  test "EH-094 should throw for detached element", %{page: page} do
    Page.set_content!(page, "<div>Hello</div>")
    div = Page.query_selector!(page, "div")
    JSHandle.evaluate!(div, "div => div.remove()")
    {:error, error} = ElementHandle.scroll_into_view_if_needed(div)
    assert Exception.message(error) =~ "Element is not attached to the DOM"
  end

  defp test_waiting(page, after_) do
    div = Page.query_selector!(page, "div")
    task = Runtime.Promise.async(fn -> ElementHandle.scroll_into_view_if_needed!(div) end, shared: true)
    Page.wait_for_timeout!(page, 1000)
    refute Runtime.Promise.settled?(task)
    JSHandle.evaluate!(div, after_)
    Runtime.Promise.await(task)
  end

  test "EH-095 should wait for display:none to become visible", %{page: page} do
    Page.set_content!(page, ~s(<div style="display:none">Hello</div>))
    test_waiting(page, "div => div.style.display = 'block'")
  end

  test "EH-096 should scroll display:contents into view", %{page: page} do
    Page.set_content!(page, """
    <style>
      html, body { margin: 0; padding: 0; width: 100%; height: 100%; }
      ::-webkit-scrollbar { display: none; }
      * { scrollbar-width: none; }
    </style>
    <div id=container style="width:200px;height:200px;overflow:scroll;border:1px solid black;">
      <div style="margin-top:500px;background:red;">
        <div style="height:50px;width:100px;background:cyan;">
          <div id=target style="display:contents">Hello</div>
        </div>
      <div>
    </div>
    """)

    div = Page.query_selector!(page, "#target")
    ElementHandle.scroll_into_view_if_needed!(div)
    scroll_top = Page.eval_on_selector!(page, "#container", "e => e.scrollTop")
    assert abs(scroll_top - 350) < 1
  end

  test "EH-097 should work for visibility:hidden element", %{page: page} do
    Page.set_content!(page, ~s(<div style="visibility:hidden">Hello</div>))
    div = Page.query_selector!(page, "div")
    ElementHandle.scroll_into_view_if_needed!(div)
  end

  test "EH-098 should work for zero-sized element", %{page: page} do
    Page.set_content!(page, ~s(<div style="height:0">Hello</div>))
    div = Page.query_selector!(page, "div")
    ElementHandle.scroll_into_view_if_needed!(div)
  end

  test "EH-099 should wait for nested display:none to become visible", %{page: page} do
    Page.set_content!(page, ~s(<span style="display:none"><div>Hello</div></span>))
    test_waiting(page, "div => div.parentElement.style.display = 'block'")
  end

  test "EH-100 should wait for element to stop moving", %{page: page} do
    Page.set_content!(page, """
    <style>
      @keyframes move {
        from { margin-left: 0; }
        to { margin-left: 200px; }
      }
      div.animated {
        animation: 2s linear 0s infinite alternate move;
      }
    </style>
    <div class=animated>moving</div>
    """)

    test_waiting(page, "div => div.classList.remove('animated')")
  end

  test "EH-101 should timeout waiting for visible", %{page: page} do
    Page.set_content!(page, ~s(<div style="display:none">Hello</div>))
    div = Page.query_selector!(page, "div")
    {:error, error} = ElementHandle.scroll_into_view_if_needed(div, timeout: 3000)
    assert Exception.message(error) =~ "element is not visible"
    assert Exception.message(error) =~ "retrying scroll into view action"
  end
end
