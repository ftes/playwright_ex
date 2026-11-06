defmodule PlaywrightEx.Page.QueryselectorTest do
  @upstream "tests/page/queryselector.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :page

  test "should throw for non-string selector", %{page: page} do
    {:error, error} = Page.query_selector(page, :null)
    assert Exception.message(error) =~ "selector: expected string, got object"
  end

  test "should query existing element with css selector @smoke", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, "css=section")
    assert element
  end

  test "should query existing element with text selector", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, ~s(text="test"))
    assert element
  end

  test "should query existing element with xpath selector", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, "xpath=/html/body/section")
    assert element
  end

  test "should return null for non-existing element", %{page: page} do
    element = Page.query_selector!(page, "non-existing-element")
    assert element == nil
  end

  test "should auto-detect xpath selector", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, "//html/body/section")
    assert element
  end

  test "should auto-detect xpath selector with starting parenthesis", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, "(//section)[1]")
    assert element
  end

  test "should auto-detect xpath selector starting with ..", %{page: page} do
    Page.set_content!(page, "<div><section>test</section><span></span></div>")
    span = Page.query_selector!(page, ~s("test" >> ../span))
    assert JSHandle.evaluate!(span, "e => e.nodeName") == "SPAN"
    div = Page.query_selector!(page, ~s("test" >> ..))
    assert JSHandle.evaluate!(div, "e => e.nodeName") == "DIV"
  end

  test "should auto-detect text selector", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, ~s("test"))
    assert element
  end

  test "should auto-detect css selector", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, "section")
    assert element
  end

  test "should support >> syntax", %{page: page} do
    Page.set_content!(page, "<section><div>test</div></section>")
    element = Page.query_selector!(page, "css=section >> css=div")
    assert element
  end

  test "should query existing elements", %{page: page} do
    Page.set_content!(page, "<div>A</div><br/><div>B</div>")
    elements = Page.query_selector_all!(page, "div")
    assert length(elements) == 2
    promises = Enum.map(elements, &Page.evaluate!(page, "e => e.textContent", &1))
    assert promises == ["A", "B"]
  end

  test "should return empty array if nothing is found", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    elements = Page.query_selector_all!(page, "div")
    assert elements == []
  end

  test "xpath should query existing element", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    elements = Page.query_selector_all!(page, "xpath=/html/body/section")
    assert Enum.at(elements, 0)
    assert length(elements) == 1
  end

  test "xpath should return empty array for non-existing element", %{page: page} do
    element = Page.query_selector_all!(page, "//html/body/non-existing-element")
    assert element == []
  end

  test "xpath should return multiple elements", %{page: page} do
    Page.set_content!(page, "<div></div><div></div>")
    elements = Page.query_selector_all!(page, "xpath=/html/body/div")
    assert length(elements) == 2
  end

  test "$$ should work with bogus Array.from", %{page: page} do
    Page.set_content!(page, "<div>hello</div><div></div>")

    div1 =
      Page.evaluate_handle!(page, """
      () => {
        Array.from = () => [];
        return document.querySelector('div');
      }
      """)

    elements = Page.query_selector_all!(page, "div")
    assert length(elements) == 2
    # Check that element handle is functional and belongs to the main world.
    assert JSHandle.evaluate!(hd(elements), "(div, div1) => div === div1", div1) == true
  end
end
