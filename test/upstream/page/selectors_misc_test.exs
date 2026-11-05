defmodule PlaywrightEx.Page.SelectorsMiscTest do
  @upstream "tests/page/selectors-misc.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  @ids "els => els.map(e => e.id).join(',')"

  test "should work for open shadow roots", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector!(page, "id=target", "e => e.textContent") == "Hello from root2"
    assert Page.eval_on_selector!(page, "data-testid=foo", "e => e.textContent") == "Hello from root1"
    assert Page.eval_on_selector_all!(page, "data-testid=foo", "els => els.length") == 3
    assert Page.query_selector!(page, "id:light=target") == nil
    assert Page.query_selector!(page, "data-testid:light=foo") == nil
    assert Page.query_selector_all!(page, "data-testid:light=foo") == []
  end

  test "should click on links in shadow dom", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/shadow-dom-link.html")
    assert Page.evaluate!(page, "() => window.clickCount") == 0
    Page.click!(page, "#inner-link")
    assert Page.evaluate!(page, "() => window.clickCount") == 1
  end

  test "should work with :visible", %{page: page} do
    Page.set_content!(page, """
    <section>
      <div id=target1></div>
      <div id=target2></div>
    </section>
    """)

    assert Page.query_selector!(page, "div:visible") == nil

    {:error, error} = Page.wait_for_selector(page, "div:visible", timeout: 1000)
    assert error.message =~ "1000ms"

    promise = Task.async(fn -> Page.wait_for_selector!(page, "div:visible", state: :attached) end)
    Page.eval_on_selector!(page, "#target2", "div => div.textContent = 'Now visible'")
    element = Task.await(promise, :infinity)
    assert JSHandle.evaluate!(element, "e => e.id") == "target2"

    assert Page.eval_on_selector!(page, "div:visible", "div => div.id") == "target2"
  end

  test "should work with >> visible=", %{page: page} do
    Page.set_content!(page, """
    <section>
      <div id=target1></div>
      <div id=target2></div>
    </section>
    """)

    assert Page.query_selector!(page, "div >> visible=true") == nil

    {:error, error} = Page.wait_for_selector(page, "div >> visible=true", timeout: 1000)
    assert error.message =~ "1000ms"

    promise = Task.async(fn -> Page.wait_for_selector!(page, "div >> visible=true", state: :attached) end)
    Page.eval_on_selector!(page, "#target2", "div => div.textContent = 'Now visible'")
    element = Task.await(promise, :infinity)
    assert JSHandle.evaluate!(element, "e => e.id") == "target2"

    assert Page.eval_on_selector!(page, "div >> visible=true", "div => div.id") == "target2"
  end

  test "should work with >> visible=false", %{page: page} do
    Page.set_content!(page, """
    <section>
      <div id=target1></div>
      <div id=target2></div>
    </section>
    """)

    Expect.to_have_count!(Page.locator(page, "div >> visible=false"), 2)
    Locator.evaluate!(Page.locator(page, "#target2"), "div => div.textContent = 'Now visible'")
    Expect.to_have_count!(Page.locator(page, "div >> visible=false"), 1)
  end

  test "should work with :nth-match", %{page: page} do
    Page.set_content!(page, """
    <section>
      <div id=target1></div>
      <div id=target2></div>
    </section>
    """)

    assert Page.query_selector!(page, ":nth-match(div, 3)") == nil
    assert Page.eval_on_selector!(page, ":nth-match(div, 1)", "e => e.id") == "target1"
    assert Page.eval_on_selector!(page, ":nth-match(div, 2)", "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, ":nth-match(section > div, 2)", "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, ":nth-match(section, div, 2)", "e => e.id") == "target1"
    assert Page.eval_on_selector!(page, ":nth-match(div, section, 3)", "e => e.id") == "target2"

    assert Page.eval_on_selector_all!(page, ":is(:nth-match(div, 1), :nth-match(div, 2))", "els => els.length") ==
             2

    {:error, error} = Page.query_selector(page, ":nth-match(div, bar, 0)")
    assert error.message =~ ~s("nth-match" engine expects a one-based index as the last argument)

    {:error, error} = Page.query_selector(page, ":nth-match(2)")
    assert error.message =~ ~s("nth-match" engine expects non-empty selector list and an index argument)

    {:error, error} = Page.query_selector(page, ":nth-match(div, bar, foo)")
    assert error.message =~ ~s("nth-match" engine expects a one-based index as the last argument)

    promise = Task.async(fn -> Page.wait_for_selector!(page, ":nth-match(div, 3)", state: :attached) end)

    Page.eval_on_selector!(page, "section", """
    section => {
      const div = document.createElement('div');
      div.setAttribute('id', 'target3');
      section.appendChild(div);
    }
    """)

    element = Task.await(promise, :infinity)
    assert JSHandle.evaluate!(element, "e => e.id") == "target3"
  end

  test "should work with nth=", %{page: page} do
    Page.set_content!(page, """
    <section>
      <div id=target1></div>
      <div id=target2></div>
    </section>
    """)

    assert Page.query_selector!(page, "div >> nth=2") == nil
    assert Page.eval_on_selector!(page, "div >> nth=0", "e => e.id") == "target1"
    assert Page.eval_on_selector!(page, "div >> nth=1", "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, "section > div >> nth=1", "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, "section, div >> nth=1", "e => e.id") == "target1"
    assert Page.eval_on_selector!(page, "div, section >> nth=2", "e => e.id") == "target2"

    promise = Task.async(fn -> Page.wait_for_selector!(page, "div >> nth=2", state: :attached) end)

    Page.eval_on_selector!(page, "section", """
    section => {
      const div = document.createElement('div');
      div.setAttribute('id', 'target3');
      section.appendChild(div);
    }
    """)

    element = Task.await(promise, :infinity)
    assert JSHandle.evaluate!(element, "e => e.id") == "target3"

    Page.set_content!(page, """
    <div>
      <div>
        <div>
          <span>hi</span>
          <span>hello</span>
        </div>
      </div>
    </div>
    """)

    assert Locator.text_content!(Page.locator(page, "div >> div >> span >> nth=1")) == "hello"
  end

  test "should work with strict mode and chaining", %{page: page} do
    Page.set_content!(page, """
    <div>
      <div>
        <div>
          <span>hi</span>
        </div>
      </div>
    </div>
    """)

    assert Locator.text_content!(Page.locator(page, "div >> div >> span")) == "hi"
  end

  test "should work with layout selectors", %{page: page} do
    # it.skip(trace === 'on')  -- we run without tracing

    #      +--+  +--+
    #      | 1|  | 2|
    #      +--+  ++-++
    #      | 3|   | 4|
    # +-------+  ++-++
    # |   0   |  | 5|
    # | +--+  +--+--+
    # | | 6|  | 7|
    # | +--+  +--+
    # |       |
    # O-------+
    #         +--+
    #         | 8|
    #         +--++--+
    #             | 9|
    #             +--+

    boxes = [
      # x, y, width, height
      [0, 0, 150, 150],
      [100, 200, 50, 50],
      [200, 200, 50, 50],
      [100, 150, 50, 50],
      [201, 150, 50, 50],
      [200, 100, 50, 50],
      [50, 50, 50, 50],
      [150, 50, 50, 50],
      [150, -51, 50, 50],
      [201, -101, 50, 50]
    ]

    Page.set_content!(page, ~s(<container style="width: 500px; height: 500px; position: relative;"></container>))

    Page.eval_on_selector!(
      page,
      "container",
      """
      (container, boxes) => {
        for (let i = 0; i < boxes.length; i++) {
          const div = document.createElement('div');
          div.style.position = 'absolute';
          div.style.overflow = 'hidden';
          div.style.boxSizing = 'border-box';
          div.style.border = '1px solid black';
          div.id = 'id' + i;
          div.textContent = 'id' + i;
          const box = boxes[i];
          div.style.left = box[0] + 'px';
          // Note that top is a flipped y coordinate.
          div.style.top = (250 - box[1] - box[3]) + 'px';
          div.style.width = box[2] + 'px';
          div.style.height = box[3] + 'px';
          container.appendChild(div);
          const span = document.createElement('span');
          span.textContent = '' + i;
          div.appendChild(span);
        }
      }
      """,
      boxes
    )

    assert Page.eval_on_selector!(page, "div:right-of(#id6)", "e => e.id") == "id7"
    assert Page.eval_on_selector!(page, "div:right-of(#id1)", "e => e.id") == "id2"
    assert Page.eval_on_selector!(page, "div:right-of(#id3)", "e => e.id") == "id4"
    assert Page.query_selector!(page, "div:right-of(#id4)") == nil
    assert Page.eval_on_selector!(page, "div:right-of(#id0)", "e => e.id") == "id7"
    assert Page.eval_on_selector!(page, "div:right-of(#id8)", "e => e.id") == "id9"
    assert Page.eval_on_selector_all!(page, "div:right-of(#id3)", @ids) == "id4,id2,id5,id7,id8,id9"
    assert Page.eval_on_selector_all!(page, "div:right-of(#id3, 50)", @ids) == "id2,id5,id7,id8"
    assert Page.eval_on_selector_all!(page, "div:right-of(#id3, 49)", @ids) == "id7,id8"

    assert Page.eval_on_selector!(page, "div:left-of(#id2)", "e => e.id") == "id1"
    assert Page.query_selector!(page, "div:left-of(#id0)") == nil
    assert Page.eval_on_selector!(page, "div:left-of(#id5)", "e => e.id") == "id0"
    assert Page.eval_on_selector!(page, "div:left-of(#id9)", "e => e.id") == "id8"
    assert Page.eval_on_selector!(page, "div:left-of(#id4)", "e => e.id") == "id3"
    assert Page.eval_on_selector_all!(page, "div:left-of(#id5)", @ids) == "id0,id7,id3,id1,id6,id8"
    assert Page.eval_on_selector_all!(page, "div:left-of(#id5, 3)", @ids) == "id7,id8"

    assert Page.eval_on_selector!(page, "div:above(#id0)", "e => e.id") == "id3"
    assert Page.eval_on_selector!(page, "div:above(#id5)", "e => e.id") == "id4"
    assert Page.eval_on_selector!(page, "div:above(#id7)", "e => e.id") == "id5"
    assert Page.eval_on_selector!(page, "div:above(#id8)", "e => e.id") == "id0"
    assert Page.eval_on_selector!(page, "div:above(#id9)", "e => e.id") == "id8"
    assert Page.query_selector!(page, "div:above(#id2)") == nil
    assert Page.eval_on_selector_all!(page, "div:above(#id5)", @ids) == "id4,id2,id3,id1"
    assert Page.eval_on_selector_all!(page, "div:above(#id5, 20)", @ids) == "id4,id3"

    assert Page.eval_on_selector!(page, "div:below(#id4)", "e => e.id") == "id5"
    assert Page.eval_on_selector!(page, "div:below(#id3)", "e => e.id") == "id0"
    assert Page.eval_on_selector!(page, "div:below(#id2)", "e => e.id") == "id4"
    assert Page.eval_on_selector!(page, "div:below(#id6)", "e => e.id") == "id8"
    assert Page.eval_on_selector!(page, "div:below(#id7)", "e => e.id") == "id8"
    assert Page.eval_on_selector!(page, "div:below(#id8)", "e => e.id") == "id9"
    assert Page.query_selector!(page, "div:below(#id9)") == nil
    assert Page.eval_on_selector_all!(page, "div:below(#id3)", @ids) == "id0,id5,id6,id7,id8,id9"
    assert Page.eval_on_selector_all!(page, "div:below(#id3, 105)", @ids) == "id0,id5,id6,id7"

    assert Page.eval_on_selector!(page, "div:near(#id0)", "e => e.id") == "id3"
    assert Page.eval_on_selector_all!(page, "div:near(#id7)", @ids) == "id0,id5,id3,id6"
    assert Page.eval_on_selector_all!(page, "div:near(#id0)", @ids) == "id3,id6,id7,id8,id1,id5"
    assert Page.eval_on_selector_all!(page, "div:near(#id6)", @ids) == "id0,id3,id7"
    assert Page.eval_on_selector_all!(page, "div:near(#id6, 10)", @ids) == "id0"
    assert Page.eval_on_selector_all!(page, "div:near(#id0, 100)", @ids) == "id3,id6,id7,id8,id1,id5,id4,id2"

    assert Page.eval_on_selector_all!(page, "div:below(#id5):above(#id8)", @ids) == "id7,id6"
    assert Page.eval_on_selector!(page, "div:below(#id5):above(#id8)", "e => e.id") == "id7"

    assert Page.eval_on_selector_all!(page, "div:right-of(#id0) + div:above(#id8)", @ids) == "id5,id6,id3"

    {:error, error} = Page.query_selector(page, ":near(50)")
    assert error.message =~ ~s("near" engine expects a selector list and optional maximum distance in pixels)
  end

  test "should escape the scope with >>", %{page: page} do
    Page.set_content!(page, "<div><label>Test</label><input id='myinput'></div>")
    assert Page.eval_on_selector!(page, "label >> xpath=.. >> input", "e => e.id") == "myinput"
  end

  test "xpath should be relative", %{page: page} do
    Page.set_content!(page, """
    <span class="find-me" id=target1>1</span>
    <div>
      <span class="find-me" id=target2>2</span>
    </div>
    """)

    assert Page.eval_on_selector!(page, ~s(//*[@class="find-me"]), "e => e.id") == "target1"

    div = Page.query_selector!(page, "div")
    assert ElementHandle.eval_on_selector!(div, ~s(xpath=./*[@class="find-me"]), "e => e.id") == "target2"
    assert ElementHandle.eval_on_selector!(div, ~s(xpath=.//*[@class="find-me"]), "e => e.id") == "target2"
    assert ElementHandle.eval_on_selector!(div, ~s(//*[@class="find-me"]), "e => e.id") == "target2"
    assert ElementHandle.eval_on_selector!(div, ~s(xpath=/*[@class="find-me"]), "e => e.id") == "target2"

    assert Page.eval_on_selector!(page, ~s(div >> xpath=./*[@class="find-me"]), "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, ~s(div >> xpath=.//*[@class="find-me"]), "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, ~s(div >> //*[@class="find-me"]), "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, ~s(div >> xpath=/*[@class="find-me"]), "e => e.id") == "target2"
  end

  test "should work with pipe in xpath", %{page: page} do
    Page.set_content!(page, """
    <span class="find-me" id=t1>1</span>
    <div>
      <span class="find-me" id=t2>2</span>
    </div>
    <div id=t3>3</span>
    """)

    assert Page.eval_on_selector_all!(page, ~s(//*[@id="t1"]|//*[@id="t3"]), "els => els.length") == 2

    e1 = Page.wait_for_selector!(page, ~s(//*[@id="t1"]|//*[@id="t3"]))
    assert e1
    assert JSHandle.evaluate!(e1, "e => e.id") == "t1"

    e2 = Page.wait_for_selector!(page, ~s(//*[@id="unknown"]|//*[@id="t2"]))
    assert e2
    assert JSHandle.evaluate!(e2, "e => e.id") == "t2"

    Page.click!(page, ~s(//code|//span[@id="t2"]))
  end

  test "should print original xpath in error", %{page: page} do
    {:error, error} = Locator.is_visible(Page.locator(page, "//*[contains(@Class, 'foo']"))
    assert error.message =~ ~S"//*[contains(@Class, \'foo\']"
    refute error.message =~ ".//*[contains(@Class, 'foo']"
  end

  test "data-testid on the handle should be relative", %{page: page} do
    Page.set_content!(page, """
    <span data-testid="find-me" id=target1>1</span>
    <div>
      <span data-testid="find-me" id=target2>2</span>
    </div>
    """)

    assert Page.eval_on_selector!(page, "data-testid=find-me", "e => e.id") == "target1"

    div = Page.query_selector!(page, "div")
    assert ElementHandle.eval_on_selector!(div, "data-testid=find-me", "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, "div >> data-testid=find-me", "e => e.id") == "target2"
  end

  test "should properly determine visibility of display:contents elements", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/11202' }
    Page.set_content!(page, """
    <div>
      <p style="display:contents">DISPLAY CONTENTS</p>
    </div>
    """)

    Page.wait_for_selector!(page, ~s("DISPLAY CONTENTS"))

    Page.set_content!(page, """
    <div>
      <article style="display:contents"><div>DISPLAY CONTENTS</div></article>
    </div>
    """)

    Page.wait_for_selector!(page, "article")

    Page.set_content!(page, """
    <div>
      <article style="display:contents"><div style="display:contents">DISPLAY CONTENTS</div></article>
    </div>
    """)

    Page.wait_for_selector!(page, "article")

    Page.set_content!(page, """
    <div>
      <article style="display:contents"><div></div>DISPLAY CONTENTS<span></span></article>
    </div>
    """)

    Page.wait_for_selector!(page, "article")

    Page.set_content!(page, """
    <div>
      <article style="display:contents"><div></div></article>
    </div>
    """)

    Page.wait_for_selector!(page, "article", state: :hidden)
  end

  test "should work with internal:has=", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:has="#target"), "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:has="[data-testid=foo]"), "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:has="[attr*=value]"), "els => els.length") == 2

    Page.set_content!(page, "<section><span></span><div></div></section><section><br></section>")
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has="span, div"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has="span, div"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has="br"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has="span, br"), "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has="span, br, div"), "els => els.length") == 2

    Page.set_content!(page, "<div><span>hello</span></div><div><span>world</span></div>")
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:has="text=world"), "els => els.length") == 1

    assert Page.eval_on_selector!(page, ~s(div >> internal:has="text=world"), "e => e.outerHTML") ==
             "<div><span>world</span></div>"

    assert Page.eval_on_selector_all!(page, ~S(div >> internal:has="text=\"hello\""), "els => els.length") == 1

    assert Page.eval_on_selector!(page, ~S(div >> internal:has="text=\"hello\""), "e => e.outerHTML") ==
             "<div><span>hello</span></div>"

    assert Page.eval_on_selector_all!(page, ~s(div >> internal:has="xpath=./span"), "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:has="span"), "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:has="span >> text=wor"), "els => els.length") == 1

    assert Page.eval_on_selector!(page, ~s(div >> internal:has="span >> text=wor"), "e => e.outerHTML") ==
             "<div><span>world</span></div>"

    assert Page.eval_on_selector!(page, ~s(div >> internal:has="span >> text=wor" >> span), "e => e.outerHTML") ==
             "<span>world</span>"

    {:error, error1} = Page.query_selector(page, "div >> internal:has=abc")
    assert error1.message =~ "Malformed selector: internal:has=abc"
    {:error, error2} = Page.query_selector(page, ~s(internal:has="div"))
    assert error2.message =~ ~s("internal:has" selector cannot be first)
    {:error, error3} = Page.query_selector(page, "div >> internal:has=33")
    assert error3.message =~ "Malformed selector: internal:has=33"
    {:error, error4} = Page.query_selector(page, ~s(div >> internal:has="span!"))
    assert error4.message =~ ~s(Unexpected token "!" while parsing css selector "span!")
  end

  test "should work with internal:has-not=", %{page: page} do
    Page.set_content!(page, "<section><span></span><div></div></section><section><br></section>")
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has-not="span"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has-not="span, div, br"), "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has-not="br"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has-not="span, div"), "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, ~s(section >> internal:has-not="article"), "els => els.length") == 2
  end

  test "should work with internal:and=", %{page: page} do
    Page.set_content!(page, """
    <div class=foo>hello</div><div class=bar>world</div>
    <span class=foo>hello2</span><span class=bar>world2</span>
    """)

    texts = "els => els.map(e => e.textContent)"
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:and="span"), texts) == []
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:and=".foo"), texts) == ["hello"]
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:and=".bar"), texts) == ["world"]
    assert Page.eval_on_selector_all!(page, ~s(span >> internal:and="span"), texts) == ["hello2", "world2"]
    assert Page.eval_on_selector_all!(page, ~s(.foo >> internal:and="div"), texts) == ["hello"]
    assert Page.eval_on_selector_all!(page, ~s(.bar >> internal:and="span"), texts) == ["world2"]
  end

  test "should work with internal:or=", %{page: page} do
    Page.set_content!(page, """
    <div>hello</div>
    <span>world</span>
    """)

    texts = "els => els.map(e => e.textContent)"
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:or="span"), texts) == ["hello", "world"]
    assert Page.eval_on_selector_all!(page, ~s(span >> internal:or="div"), texts) == ["hello", "world"]
    assert Page.eval_on_selector_all!(page, ~s(article >> internal:or="something"), "els => els.length") == 0
    assert Locator.text_content!(Page.locator(page, ~s(article >> internal:or="div"))) == "hello"
    assert Locator.text_content!(Page.locator(page, ~s(article >> internal:or="span"))) == "world"
    assert Locator.text_content!(Page.locator(page, ~s(div >> internal:or="article"))) == "hello"
    assert Locator.text_content!(Page.locator(page, ~s(span >> internal:or="article"))) == "world"
  end

  test "should work with internal:chain=", %{page: page} do
    Page.set_content!(page, """
    <div>one <span>two</span> <button>three</button> </div>
    <span>four</span>
    <button>five</button>
    """)

    texts = "els => els.map(e => e.textContent)"
    assert Page.eval_on_selector_all!(page, ~s(div >> internal:chain="button"), texts) == ["three"]

    assert Page.eval_on_selector_all!(page, ~S(div >> internal:chain="span >> internal:or=\"button\""), texts) ==
             ["two", "three"]
  end

  test "chaining should work with large DOM @smoke", %{page: page} do
    Page.evaluate!(page, """
    () => {
      let last = document.body;
      for (let i = 0; i < 100; i++) {
        const e = document.createElement('div');
        last.appendChild(e);
        last = e;
      }
      const target = document.createElement('span');
      target.textContent = 'Found me!';
      last.appendChild(target);
    }
    """)

    # Naive implementation generates C(100, 9) ~= 1.9*10^12 entries.
    selectors = [
      "div >> div >> div >> div >> div >> div >> div >> div >> span",
      "div div div div div div div div span",
      "div div >> div div >> div div >> div div >> span"
    ]

    counts = for selector <- selectors, do: Page.eval_on_selector_all!(page, selector, "els => els.length")
    assert counts == [1, 1, 1]
  end
end
