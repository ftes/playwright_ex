defmodule PlaywrightEx.Page.ElementhandleQuerySelectorTest do
  @upstream "tests/page/elementhandle-query-selector.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should query existing element", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/playground.html")
    Page.set_content!(page, ~s(<html><body><div class="second"><div class="inner">A</div></div></body></html>))
    html = Page.query_selector!(page, "html")
    second = ElementHandle.query_selector!(html, ".second")
    inner = ElementHandle.query_selector!(second, ".inner")
    content = Page.evaluate!(page, "e => e.textContent", inner)
    assert content == "A"
  end

  test "should return null for non-existing element", %{page: page} do
    Page.set_content!(page, ~s(<html><body><div class="second"><div class="inner">B</div></div></body></html>))
    html = Page.query_selector!(page, "html")
    second = ElementHandle.query_selector!(html, ".third")
    assert second == nil
  end

  test "should work for adopted elements", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    popup =
      Page.expect_event!(page, :popup, fn ->
        Page.evaluate!(page, "url => window['__popup'] = window.open(url)", server.empty_page)
      end)

    div_handle =
      Page.evaluate_handle!(page, """
      () => {
        const div = document.createElement('div');
        document.body.appendChild(div);
        const span = document.createElement('span');
        span.textContent = 'hello';
        div.appendChild(span);
        return div;
      }
      """)

    assert ElementHandle.query_selector!(div_handle, "span")
    assert ElementHandle.eval_on_selector!(div_handle, "span", "e => e.textContent") == "hello"

    Page.wait_for_load_state!(popup, :domcontentloaded)

    Page.evaluate!(page, """
    () => {
      const div = document.querySelector('div');
      window['__popup'].document.body.appendChild(div);
    }
    """)

    assert ElementHandle.query_selector!(div_handle, "span")
    assert ElementHandle.eval_on_selector!(div_handle, "span", "e => e.textContent") == "hello"
  end

  test "should query existing elements", %{page: page} do
    Page.set_content!(page, "<html><body><div>A</div><br/><div>B</div></body></html>")
    html = Page.query_selector!(page, "html")
    elements = ElementHandle.query_selector_all!(html, "div")
    assert length(elements) == 2

    tasks =
      Enum.map(elements, fn element -> Task.async(fn -> Page.evaluate!(page, "e => e.textContent", element) end) end)

    assert Task.await_many(tasks) == ["A", "B"]
  end

  test "should return empty array for non-existing elements", %{page: page} do
    Page.set_content!(page, "<html><body><span>A</span><br/><span>B</span></body></html>")
    html = Page.query_selector!(page, "html")
    elements = ElementHandle.query_selector_all!(html, "div")
    assert elements == []
  end

  test "xpath should query existing element", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/playground.html")
    Page.set_content!(page, ~s(<html><body><div class="second"><div class="inner">A</div></div></body></html>))
    html = Page.query_selector!(page, "html")
    second = ElementHandle.query_selector_all!(html, "xpath=./body/div[contains(@class, 'second')]")
    inner = ElementHandle.query_selector_all!(hd(second), "xpath=./div[contains(@class, 'inner')]")
    content = Page.evaluate!(page, "e => e.textContent", hd(inner))
    assert content == "A"
  end

  test "xpath should return null for non-existing element", %{page: page} do
    Page.set_content!(page, ~s(<html><body><div class="second"><div class="inner">B</div></div></body></html>))
    html = Page.query_selector!(page, "html")
    second = ElementHandle.query_selector_all!(html, "xpath=/div[contains(@class, 'third')]")
    assert second == []
  end
end
