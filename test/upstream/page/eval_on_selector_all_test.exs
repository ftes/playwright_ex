defmodule PlaywrightEx.Page.EvalOnSelectorAllTest do
  @upstream "tests/page/eval-on-selector-all.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "should work with css selector", %{page: page} do
    Page.set_content!(page, "<div>hello</div><div>beautiful</div><div>world!</div>")
    divs_count = Page.eval_on_selector_all!(page, "css=div", "divs => divs.length")
    assert divs_count == 3
  end

  test "should work with text selector", %{page: page} do
    Page.set_content!(page, "<div>hello</div><div>beautiful</div><div>beautiful</div><div>world!</div>")
    divs_count = Page.eval_on_selector_all!(page, ~s(text="beautiful"), "divs => divs.length")
    assert divs_count == 2
  end

  test "should work with xpath selector", %{page: page} do
    Page.set_content!(page, "<div>hello</div><div>beautiful</div><div>world!</div>")
    divs_count = Page.eval_on_selector_all!(page, "xpath=/html/body/div", "divs => divs.length")
    assert divs_count == 3
  end

  test "should auto-detect css selector", %{page: page} do
    Page.set_content!(page, "<div>hello</div><div>beautiful</div><div>world!</div>")
    divs_count = Page.eval_on_selector_all!(page, "div", "divs => divs.length")
    assert divs_count == 3
  end

  test "should support >> syntax", %{page: page} do
    Page.set_content!(
      page,
      "<div><span>hello</span></div><div>beautiful</div><div><span>wo</span><span>rld!</span></div><span>Not this one</span>"
    )

    spans_count = Page.eval_on_selector_all!(page, "css=div >> css=span", "spans => spans.length")
    assert spans_count == 3
  end

  test "should support * capture", %{page: page} do
    Page.set_content!(
      page,
      "<section><div><span>a</span></div></section><section><div><span>b</span></div></section>"
    )

    assert Page.eval_on_selector_all!(page, ~s(*css=div >> "b"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> *css=div >> "b"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "section >> *", "els => els.length") == 4

    Page.set_content!(page, "<section><div><span>a</span><span>a</span></div></section>")
    assert Page.eval_on_selector_all!(page, ~s(*css=div >> "a"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> *css=div >> "a"), "els => els.length") == 1

    Page.set_content!(
      page,
      "<div><span>a</span></div><div><span>a</span></div><section><div><span>a</span></div></section>"
    )

    assert Page.eval_on_selector_all!(page, ~s(*css=div >> "a"), "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, ~s(section >> *css=div >> "a"), "els => els.length") == 1
  end

  test "should support * capture when multiple paths match", %{page: page} do
    Page.set_content!(page, "<div><div><span></span></div></div><div></div>")
    assert Page.eval_on_selector_all!(page, "*css=div >> span", "els => els.length") == 2
    Page.set_content!(page, "<div><div><span></span></div><span></span><span></span></div><div></div>")
    assert Page.eval_on_selector_all!(page, "*css=div >> span", "els => els.length") == 2
  end

  test "should return complex values", %{page: page} do
    Page.set_content!(page, "<div>hello</div><div>beautiful</div><div>world!</div>")
    texts = Page.eval_on_selector_all!(page, "css=div", "divs => divs.map(div => div.textContent)")
    assert texts == ["hello", "beautiful", "world!"]
  end

  test "should work with bogus Array.from", %{page: page} do
    Page.set_content!(page, "<div>hello</div><div>beautiful</div><div>world!</div>")

    Page.evaluate!(page, """
    () => {
      Array.from = () => [];
    }
    """)

    divs_count = Page.eval_on_selector_all!(page, "css=div", "divs => divs.length")
    assert divs_count == 3
  end
end
