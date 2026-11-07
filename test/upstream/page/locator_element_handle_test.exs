defmodule PlaywrightEx.Page.LocatorElementHandleTest do
  @upstream "tests/page/locator-element-handle.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "LO-079 should query existing element @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/playground.html")
    Page.set_content!(page, ~s(<html><body><div class="second"><div class="inner">A</div></div></body></html>))
    html = Page.locator(page, "html")
    second = Locator.locator(html, ".second")
    inner = Locator.locator(second, ".inner")
    content = Page.evaluate!(page, "e => e.textContent", Locator.element_handle!(inner))
    assert content == "A"
  end

  test "LO-080 should query existing elements", %{page: page} do
    Page.set_content!(page, "<html><body><div>A</div><br/><div>B</div></body></html>")
    html = Page.locator(page, "html")
    elements = Locator.element_handles!(Locator.locator(html, "div"))
    assert length(elements) == 2

    tasks =
      Enum.map(elements, fn element -> Task.async(fn -> Page.evaluate!(page, "e => e.textContent", element) end) end)

    assert Task.await_many(tasks, :infinity) == ["A", "B"]
  end

  test "LO-081 should return empty array for non-existing elements", %{page: page} do
    Page.set_content!(page, "<html><body><span>A</span><br/><span>B</span></body></html>")
    html = Page.locator(page, "html")
    elements = Locator.element_handles!(Locator.locator(html, "div"))
    assert elements == []
  end

  test "LO-082 xpath should query existing element", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/playground.html")
    Page.set_content!(page, ~s(<html><body><div class="second"><div class="inner">A</div></div></body></html>))
    html = Page.locator(page, "html")
    second = Locator.locator(html, "xpath=./body/div[contains(@class, 'second')]")
    inner = Locator.locator(second, "xpath=./div[contains(@class, 'inner')]")
    content = Page.evaluate!(page, "e => e.textContent", Locator.element_handle!(inner))
    assert content == "A"
  end

  test "LO-083 xpath should return null for non-existing element", %{page: page} do
    Page.set_content!(page, ~s(<html><body><div class="second"><div class="inner">B</div></div></body></html>))
    html = Page.locator(page, "html")
    second = Locator.element_handles!(Locator.locator(html, "xpath=/div[contains(@class, 'third')]"))
    assert second == []
  end
end
