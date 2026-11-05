defmodule PlaywrightEx.Page.EvalOnSelectorTest do
  @upstream "tests/page/eval-on-selector.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "should work with css selector", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "css=section", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should work with id selector", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "id=testAttribute", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should work with data-test selector", %{page: page} do
    Page.set_content!(page, ~s(<section data-test=foo id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "data-test=foo", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should work with data-testid selector", %{page: page} do
    Page.set_content!(page, ~s(<section data-testid=foo id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "data-testid=foo", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should work with data-test-id selector", %{page: page} do
    Page.set_content!(page, ~s(<section data-test-id=foo id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "data-test-id=foo", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should work with text selector in quotes", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, ~s(text="43543"), "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should work with xpath selector", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "xpath=/html/body/section", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should work with text selector", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "text=43543", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should auto-detect css selector", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "section", "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should auto-detect css selector with attributes", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, ~s(section[id="testAttribute"]), "e => e.id")
    assert id_attribute == "testAttribute"
  end

  test "should auto-detect nested selectors", %{page: page} do
    Page.set_content!(page, "<div foo=bar><section>43543<span>Hello<div id=target></div></span></section></div>")
    id_attribute = Page.eval_on_selector!(page, ~s(div[foo=bar] > section >> "Hello" >> div), "e => e.id")
    assert id_attribute == "target"
  end

  test "should accept arguments", %{page: page} do
    Page.set_content!(page, "<section>hello</section>")
    text = Page.eval_on_selector!(page, "section", "(e, suffix) => e.textContent + suffix", " world!")
    assert text == "hello world!"
  end

  test "should accept ElementHandles as arguments", %{page: page} do
    Page.set_content!(page, "<section>hello</section><div> world</div>")
    div_handle = Page.query_selector!(page, "div")
    text = Page.eval_on_selector!(page, "section", "(e, div) => e.textContent + div.textContent", div_handle)
    assert text == "hello world"
  end

  test "should throw error if no element is found", %{page: page} do
    {:error, error} = Page.eval_on_selector(page, "section", "e => e.id")
    assert Exception.message(error) =~ ~s(Failed to find element matching selector "section")
  end

  test "should support >> syntax", %{page: page} do
    Page.set_content!(page, "<section><div>hello</div></section>")
    text = Page.eval_on_selector!(page, "css=section >> css=div", "(e, suffix) => e.textContent + suffix", " world!")
    assert text == "hello world!"
  end

  test "should support >> syntax with different engines", %{page: page} do
    Page.set_content!(page, "<section><div><span>hello</span></div></section>")

    text =
      Page.eval_on_selector!(
        page,
        ~s(xpath=/html/body/section >> css=div >> text="hello"),
        "(e, suffix) => e.textContent + suffix",
        " world!"
      )

    assert text == "hello world!"
  end

  test "should support spaces with >> syntax", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    text = Page.eval_on_selector!(page, " css = div >>css=div>>css   = span  ", "e => e.textContent")
    assert text == "Hello from root2"
  end

  test "should not stop at first failure with >> syntax", %{page: page} do
    Page.set_content!(page, "<div><span>Next</span><button>Previous</button><button>Next</button></div>")
    html = Page.eval_on_selector!(page, ~s(button >> "Next"), "e => e.outerHTML")
    assert html == "<button>Next</button>"
  end

  test "should support * capture", %{page: page} do
    Page.set_content!(
      page,
      "<section><div><span>a</span></div></section><section><div><span>b</span></div></section>"
    )

    assert Page.eval_on_selector!(page, ~s(*css=div >> "b"), "e => e.outerHTML") == "<div><span>b</span></div>"

    assert Page.eval_on_selector!(page, ~s(section >> *css=div >> "b"), "e => e.outerHTML") ==
             "<div><span>b</span></div>"

    assert Page.eval_on_selector!(page, ~s(css=div >> *text="b"), "e => e.outerHTML") == "<span>b</span>"
    assert Page.query_selector!(page, "*")
  end

  test "should throw on multiple * captures", %{page: page} do
    {:error, error} = Page.eval_on_selector(page, "*css=div >> *css=span", "e => e.outerHTML")
    assert Exception.message(error) =~ "Only one of the selectors can capture using * modifier"
  end

  test "should throw on malformed * capture", %{page: page} do
    {:error, error} = Page.eval_on_selector(page, "*=div", "e => e.outerHTML")
    assert Exception.message(error) =~ ~s(Unknown engine "" while parsing selector *=div)
  end

  test "should work with spaces in css attributes", %{page: page} do
    Page.set_content!(page, ~s(<div><input placeholder="Select date"></div>))
    assert Page.wait_for_selector!(page, ~s([placeholder="Select date"]))
    assert Page.wait_for_selector!(page, "[placeholder='Select date']")
    assert Page.wait_for_selector!(page, ~s(input[placeholder="Select date"]))
    assert Page.wait_for_selector!(page, "input[placeholder='Select date']")
    assert Page.query_selector!(page, ~s([placeholder="Select date"]))
    assert Page.query_selector!(page, "[placeholder='Select date']")
    assert Page.query_selector!(page, ~s(input[placeholder="Select date"]))
    assert Page.query_selector!(page, "input[placeholder='Select date']")
    expected = ~s(<input placeholder="Select date">)
    assert Page.eval_on_selector!(page, ~s([placeholder="Select date"]), "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, "[placeholder='Select date']", "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, ~s(input[placeholder="Select date"]), "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, "input[placeholder='Select date']", "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, ~s(css=[placeholder="Select date"]), "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, "css=[placeholder='Select date']", "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, ~s(css=input[placeholder="Select date"]), "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, "css=input[placeholder='Select date']", "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, ~s(div >> [placeholder="Select date"]), "e => e.outerHTML") == expected
    assert Page.eval_on_selector!(page, "div >> [placeholder='Select date']", "e => e.outerHTML") == expected
  end

  test "should work with quotes in css attributes", %{page: page} do
    Page.set_content!(page, ~s(<div><input placeholder="Select&quot;date"></div>))
    assert Page.query_selector!(page, ~S([placeholder="Select\"date"]))
    assert Page.query_selector!(page, ~s([placeholder='Select"date']))
    Page.set_content!(page, ~s(<div><input placeholder="Select &quot; date"></div>))
    assert Page.query_selector!(page, ~S([placeholder="Select \" date"]))
    assert Page.query_selector!(page, ~s([placeholder='Select " date']))
    Page.set_content!(page, ~s(<div><input placeholder="Select&apos;date"></div>))
    assert Page.query_selector!(page, ~s([placeholder="Select'date"]))
    assert Page.query_selector!(page, ~S([placeholder='Select\'date']))
    Page.set_content!(page, ~s(<div><input placeholder="Select &apos; date"></div>))
    assert Page.query_selector!(page, ~s([placeholder="Select ' date"]))
    assert Page.query_selector!(page, ~S([placeholder='Select \' date']))
  end

  test "should work with spaces in css attributes when missing", %{page: page} do
    input_promise = Task.async(fn -> Page.wait_for_selector!(page, ~s([placeholder="Select date"])) end)
    assert Page.query_selector!(page, ~s([placeholder="Select date"])) == nil
    Page.set_content!(page, ~s(<div><input placeholder="Select date"></div>))
    Task.await(input_promise, :infinity)
  end

  test "should work with quotes in css attributes when missing", %{page: page} do
    input_promise = Task.async(fn -> Page.wait_for_selector!(page, ~S([placeholder="Select\"date"])) end)
    assert Page.query_selector!(page, ~S([placeholder="Select\"date"])) == nil
    Page.set_content!(page, ~s(<div><input placeholder="Select&quot;date"></div>))
    Task.await(input_promise, :infinity)
  end

  test "should return complex values", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    id_attribute = Page.eval_on_selector!(page, "css=section", "e => [{ id: e.id }]")
    assert id_attribute == [%{"id" => "testAttribute"}]
  end
end
