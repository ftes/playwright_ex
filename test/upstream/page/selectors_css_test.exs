defmodule PlaywrightEx.Page.SelectorsCssTest do
  @upstream "tests/page/selectors-css.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  @node_names "els => els.map(e => e.nodeName).join(',')"

  test "SE-001 should work with large DOM @smoke", %{page: page} do
    Page.evaluate!(page, """
    () => {
      let id = 0;
      const next = (tag) => {
        const e = document.createElement(tag);
        const eid = ++id;
        e.textContent = 'id' + eid;
        e.id = '' + eid;
        return e;
      };
      const generate = (depth) => {
        const div = next('div');
        const span1 = next('span');
        const span2 = next('span');
        div.appendChild(span1);
        div.appendChild(span2);
        if (depth > 0) {
          div.appendChild(generate(depth - 1));
          div.appendChild(generate(depth - 1));
        }
        return div;
      };
      document.body.appendChild(generate(12));
    }
    """)

    selectors = [
      "div div div span",
      "div > div div > span",
      "div + div div div span + span",
      "div ~ div div > span ~ span",
      "div > div > div + div > div + div > span ~ span",
      "div div div div div div div div div div span",
      "div > div > div > div > div > div > div > div > div > div > span",
      "div ~ div div ~ div div ~ div div ~ div div ~ div span",
      "span"
    ]

    # Upstream's `measure` is false: one iteration each, no timing output.
    for selector <- selectors do
      counts1 = [Page.eval_on_selector_all!(page, selector, "els => els.length")]

      counts2 = [
        Page.evaluate!(page, "selector => document.querySelectorAll(selector).length", selector)
      ]

      assert counts1 == counts2
    end
  end

  test "SE-002 should work for open shadow roots", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector!(page, "css=span", "e => e.textContent") == "Hello from root1"
    assert Page.eval_on_selector!(page, ~S{css=[attr="value\ space"]}, "e => e.textContent") == "Hello from root3 #2"
    assert Page.eval_on_selector!(page, ~S{css=[attr='value\ \space']}, "e => e.textContent") == "Hello from root3 #2"
    assert Page.eval_on_selector!(page, "css=div div span", "e => e.textContent") == "Hello from root2"
    assert Page.eval_on_selector!(page, "css=div span + span", "e => e.textContent") == "Hello from root3 #2"
    assert Page.eval_on_selector!(page, ~s{css=span + [attr*="value"]}, "e => e.textContent") == "Hello from root3 #2"

    assert Page.eval_on_selector!(page, ~s{css=[data-testid="foo"] + [attr*="value"]}, "e => e.textContent") ==
             "Hello from root3 #2"

    assert Page.eval_on_selector!(page, "css=#target", "e => e.textContent") == "Hello from root2"
    assert Page.eval_on_selector!(page, "css=div #target", "e => e.textContent") == "Hello from root2"
    assert Page.eval_on_selector!(page, "css=div div #target", "e => e.textContent") == "Hello from root2"
    assert Page.query_selector!(page, "css=div div div #target") == nil
    assert Page.eval_on_selector!(page, "css=section > div div span", "e => e.textContent") == "Hello from root2"

    assert Page.eval_on_selector!(page, "css=section > div div span:nth-child(2)", "e => e.textContent") ==
             "Hello from root3 #2"

    assert Page.query_selector!(page, "css=section div div div div") == nil

    root2 = Page.query_selector!(page, "css=div div")
    assert ElementHandle.eval_on_selector!(root2, "css=#target", "e => e.textContent") == "Hello from root2"
    assert ElementHandle.query_selector!(root2, "css:light=#target") == nil
    root2_shadow = JSHandle.evaluate_handle!(root2, "r => r.shadowRoot")

    assert ElementHandle.eval_on_selector!(root2_shadow, "css:light=#target", "e => e.textContent") ==
             "Hello from root2"

    root3 = Enum.at(Page.query_selector_all!(page, "css=div div"), 1)
    assert ElementHandle.eval_on_selector!(root3, "text=root3", "e => e.textContent") == "Hello from root3"

    assert ElementHandle.eval_on_selector!(root3, ~s{css=[attr*="value"]}, "e => e.textContent") ==
             "Hello from root3 #2"

    assert ElementHandle.query_selector!(root3, ~s{css:light=[attr*="value"]}) == nil
  end

  test "SE-003 should work with > combinator and spaces", %{page: page} do
    Page.set_content!(page, ~s{<div foo="bar" bar="baz"><span></span></div>})
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"] > span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"]> span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"] >span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"]>span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"]   >    span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"]>    span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"]     >span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"][bar="baz"] > span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"][bar="baz"]> span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"][bar="baz"] >span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"][bar="baz"]>span}, "e => e.outerHTML") == "<span></span>"

    assert Page.eval_on_selector!(page, ~s{div[foo="bar"][bar="baz"]   >    span}, "e => e.outerHTML") ==
             "<span></span>"

    assert Page.eval_on_selector!(page, ~s{div[foo="bar"][bar="baz"]>    span}, "e => e.outerHTML") == "<span></span>"
    assert Page.eval_on_selector!(page, ~s{div[foo="bar"][bar="baz"]     >span}, "e => e.outerHTML") == "<span></span>"
  end

  test "SE-004 should work with comma separated list", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector_all!(page, "css=span,section #root1", "els => els.length") == 5
    assert Page.eval_on_selector_all!(page, "css=section #root1, div span", "els => els.length") == 5
    assert Page.eval_on_selector!(page, "css=doesnotexist , section #root1", "e => e.id") == "root1"
    assert Page.eval_on_selector_all!(page, "css=doesnotexist ,section #root1", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span,div span", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "css=span,div span,div div span", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, ~S{css=#target,[attr="value\ space"]}, "els => els.length") == 2

    assert Page.eval_on_selector_all!(
             page,
             ~S{css=#target,[data-testid="foo"],[attr="value\ space"]},
             "els => els.length"
           ) == 4

    assert Page.eval_on_selector_all!(
             page,
             ~S{css=#target,[data-testid="foo"],[attr="value\ space"],span},
             "els => els.length"
           ) == 4
  end

  test "SE-005 should keep dom order with comma separated list", %{page: page} do
    Page.set_content!(page, "<section><span><div><x></x><y></y></div></span></section>")
    assert Page.eval_on_selector_all!(page, "css=span,div", @node_names) == "SPAN,DIV"
    assert Page.eval_on_selector_all!(page, "css=div,span", @node_names) == "SPAN,DIV"
    assert Page.eval_on_selector_all!(page, "css=span div, div", @node_names) == "DIV"
    assert Page.eval_on_selector_all!(page, "*css=section >> css=div,span", @node_names) == "SECTION"
    assert Page.eval_on_selector_all!(page, "css=section >> *css=div >> css=x,y", @node_names) == "DIV"
    assert Page.eval_on_selector_all!(page, "css=section >> *css=div,span >> css=x,y", @node_names) == "SPAN,DIV"
    assert Page.eval_on_selector_all!(page, "css=section >> *css=div,span >> css=y", @node_names) == "SPAN,DIV"
  end

  test "SE-006 should return multiple captures for the same node", %{page: page} do
    Page.set_content!(page, "<div><div><div><span></span></div></div></div>")
    assert Page.eval_on_selector_all!(page, "*css=div >> span", @node_names) == "DIV,DIV,DIV"
  end

  test "SE-007 should return multiple captures when going up the hierarchy", %{page: page} do
    Page.set_content!(page, "<section>Hello<ul><li></li><li></li></ul></section>")
    assert Page.eval_on_selector_all!(page, "*css=li >> ../.. >> text=Hello", @node_names) == "LI,LI"
  end

  test "SE-008 should work with comma separated list in various positions", %{page: page} do
    Page.set_content!(page, "<section><span><div><x></x><y></y></div></span></section>")
    assert Page.eval_on_selector_all!(page, "css=span,div >> css=x,y", @node_names) == "X,Y"
    assert Page.eval_on_selector_all!(page, "css=span,div >> css=x", @node_names) == "X"
    assert Page.eval_on_selector_all!(page, "css=div >> css=x,y", @node_names) == "X,Y"
    assert Page.eval_on_selector_all!(page, "css=div >> css=x", @node_names) == "X"

    assert Page.eval_on_selector_all!(page, "css=section >> css=div >> css=x", @node_names) == "X"
    assert Page.eval_on_selector_all!(page, "css=section >> css=span >> css=div >> css=y", @node_names) == "Y"
    assert Page.eval_on_selector_all!(page, "css=section >> css=div >> css=x,y", @node_names) == "X,Y"
    assert Page.eval_on_selector_all!(page, "css=section >> css=div,span >> css=x,y", @node_names) == "X,Y"
    assert Page.eval_on_selector_all!(page, "css=section >> css=span >> css=x,y", @node_names) == "X,Y"
  end

  test "SE-009 should work with comma inside text", %{page: page} do
    Page.set_content!(page, ~s{<span></span><div attr="hello,world!"></div>})

    assert Page.eval_on_selector!(page, ~s{css=div[attr="hello,world!"]}, "e => e.outerHTML") ==
             ~s{<div attr="hello,world!"></div>}

    assert Page.eval_on_selector!(page, ~s{css=[attr="hello,world!"]}, "e => e.outerHTML") ==
             ~s{<div attr="hello,world!"></div>}

    assert Page.eval_on_selector!(page, "css=div[attr='hello,world!']", "e => e.outerHTML") ==
             ~s{<div attr="hello,world!"></div>}

    assert Page.eval_on_selector!(page, "css=[attr='hello,world!']", "e => e.outerHTML") ==
             ~s{<div attr="hello,world!"></div>}

    assert Page.eval_on_selector!(page, ~s{css=div[attr="hello,world!"],span}, "e => e.outerHTML") == "<span></span>"
  end

  test "SE-010 should work with attribute selectors", %{page: page} do
    Page.set_content!(page, ~s{<div attr="hello world" attr2="hello-''>>foo=bar[]" attr3="] span"><span></span></div>})
    Page.evaluate!(page, "() => window['div'] = document.querySelector('div')")

    selectors = [
      ~s{[attr="hello world"]},
      ~s{[attr = "hello world"]},
      "[attr ~= world]",
      "[attr ^=hello ]",
      "[attr $= world ]",
      ~s{[attr *= "llo wor" ]},
      "[attr2 |= hello]",
      ~s{[attr = "Hello World" i ]},
      ~s{[attr *= "llo WOR"i]},
      "[attr $= woRLD i]",
      ~s{[attr2 = "hello-''>>foo=bar[]"]},
      ~s{[attr2 $="foo=bar[]"]}
    ]

    for selector <- selectors do
      assert Page.eval_on_selector!(page, selector, "e => e === window['div']") == true
    end

    assert Page.eval_on_selector!(page, "[attr*=hello] span", "e => e.parentNode === window['div']") == true
    assert Page.eval_on_selector!(page, "[attr*=hello] >> span", "e => e.parentNode === window['div']") == true
    assert Page.eval_on_selector!(page, ~s{[attr3="] span"] >> span}, "e => e.parentNode === window['div']") == true
  end

  test "SE-011 should not match root after >>", %{page: page} do
    Page.set_content!(page, "<section><div>test</div></section>")
    element = Page.query_selector!(page, "css=section >> css=section")
    assert element == nil
  end

  test "SE-012 should work with numerical id", %{page: page} do
    Page.set_content!(page, ~s{<section id="123"></section>})
    element = Page.query_selector!(page, ~S{#\31\32\33})
    assert element
  end

  test "SE-013 should work with wrong-case id", %{page: page} do
    Page.set_content!(page, ~s{<section id="Hello"></section>})
    assert Page.eval_on_selector!(page, "#Hello", "e => e.tagName") == "SECTION"
    assert Page.eval_on_selector!(page, "#hello", "e => e.tagName") == "SECTION"
    assert Page.eval_on_selector!(page, "#HELLO", "e => e.tagName") == "SECTION"
    assert Page.eval_on_selector!(page, "#helLO", "e => e.tagName") == "SECTION"
  end

  test "SE-014 should work with *", %{page: page} do
    Page.set_content!(page, "<div id=div1></div><div id=div2><span><span></span></span></div>")
    # Includes html, head and body.
    assert Page.eval_on_selector_all!(page, "*", "els => els.length") == 7
    assert Page.eval_on_selector_all!(page, "*#div1", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "*:not(#div1)", "els => els.length") == 6
    assert Page.eval_on_selector_all!(page, "*:not(div)", "els => els.length") == 5
    assert Page.eval_on_selector_all!(page, "*:not(span)", "els => els.length") == 5
    assert Page.eval_on_selector_all!(page, "*:not(*)", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "*:is(*)", "els => els.length") == 7
    assert Page.eval_on_selector_all!(page, "* *", "els => els.length") == 6
    assert Page.eval_on_selector_all!(page, "* *:not(span)", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "div > *", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "div *", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "* > *", "els => els.length") == 6

    body = Page.query_selector!(page, "body")
    # Does not include html, head or body.
    assert ElementHandle.eval_on_selector_all!(body, "*", "els => els.length") == 4
    assert ElementHandle.eval_on_selector_all!(body, "*#div1", "els => els.length") == 1
    assert ElementHandle.eval_on_selector_all!(body, "*:not(#div1)", "els => els.length") == 3
    assert ElementHandle.eval_on_selector_all!(body, "*:not(div)", "els => els.length") == 2
    assert ElementHandle.eval_on_selector_all!(body, "*:not(span)", "els => els.length") == 2
    assert ElementHandle.eval_on_selector_all!(body, "*:not(*)", "els => els.length") == 0
    assert ElementHandle.eval_on_selector_all!(body, "*:is(*)", "els => els.length") == 4
    assert ElementHandle.eval_on_selector_all!(body, "div > *", "els => els.length") == 1
    assert ElementHandle.eval_on_selector_all!(body, "div *", "els => els.length") == 2
    # Selectors v2 matches jquery in the sense that matching starts with the element scope,
    # not the document scope.
    assert ElementHandle.eval_on_selector_all!(body, "* > *", "els => els.length") == 2
    # Adding scope makes querySelectorAll work like jquery.
    assert ElementHandle.eval_on_selector_all!(body, ":scope * > *", "els => els.length") == 2
    # Note that the following two selectors are following jquery logic even
    # with selectors v1. Just running `body.querySelectorAll` returns 4 and 2 respectively.
    # That's probably a bug in v1, but oh well.
    assert ElementHandle.eval_on_selector_all!(body, "* *", "els => els.length") == 2
    assert ElementHandle.eval_on_selector_all!(body, "* *:not(span)", "els => els.length") == 0
  end

  test "SE-015 should work with :nth-child", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(odd)", "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(even)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(n+1)", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(n+2)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(2n)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(2n+1)", "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(-n)", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(-n+1)", "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(-n+2)", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(23n+2)", "els => els.length") == 1
  end

  @tag skip:
         if(@browser_name == "chromium" and @browser_major_version < 111,
           do: "upstream skip: https://caniuse.com/css-nth-child-of"
         )
  test "SE-016 should work with :nth-child(of) notation with nested functions", %{
    page: page
  } do
    Page.set_content!(page, """
      <div>
        <span>span1</span>
        <span class=foo>span2<dd></dd></span>
        <span class=foo>span3<dd class=marker></dd></span>
        <span class=foo>span4<dd class=marker></dd></span>
        <span class=foo>span5<dd></dd></span>
        <span>span6</span>
      </div>
    """)

    texts = "els => els.map(e => e.textContent)"
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(1)", texts) == ["span1"]
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(1 of .foo)", texts) == ["span2"]
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(1 of .foo:has(dd.marker))", texts) == ["span3"]
    assert Page.eval_on_selector_all!(page, "css=span:nth-last-child(1 of .foo:has(dd.marker))", texts) == ["span4"]
    assert Page.eval_on_selector_all!(page, "css=span:nth-last-child(1 of .foo)", texts) == ["span5"]
    assert Page.eval_on_selector_all!(page, "css=span:nth-last-child(  1  )", texts) == ["span6"]

    assert Page.eval_on_selector_all!(page, "css=span:nth-child(1 of .foo:nth-child(3))", texts) == ["span3"]
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(1 of .foo:nth-child(6))", texts) == []
  end

  test "SE-017 should work with :not", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector_all!(page, "css=div:not(#root1)", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "css=body :not(span)", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "css=div > :not(span):not(div)", "els => els.length") == 0
  end

  test "SE-018 should work with ~", %{page: page} do
    Page.set_content!(page, """
      <div id=div1></div>
      <div id=div2></div>
      <div id=div3></div>
      <div id=div4></div>
      <div id=div5></div>
      <div id=div6></div>
    """)

    ids = "els => els.map(e => e.id)"
    assert Page.eval_on_selector_all!(page, "#div3 >> :scope ~ div", ids) == ["div4", "div5", "div6"]
    assert Page.eval_on_selector_all!(page, "#div3 >> :scope ~ *", ids) == ["div4", "div5", "div6"]
    assert Page.eval_on_selector_all!(page, "#div3 >> ~ div", ids) == ["div4", "div5", "div6"]
    assert Page.eval_on_selector_all!(page, "#div3 >> ~ *", ids) == ["div4", "div5", "div6"]
    assert Page.eval_on_selector_all!(page, "#div3 >> #div1 ~ :scope", ids) == ["div3"]
    assert Page.eval_on_selector_all!(page, "#div3 >> #div4 ~ :scope", ids) == []
    assert Page.eval_on_selector_all!(page, "css=#div1 ~ div ~ #div6", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=#div1 ~ div ~ div", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "css=#div3 ~ div ~ div", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "css=#div4 ~ div ~ div", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=#div5 ~ div ~ div", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=#div3 ~ #div2 ~ #div6", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=#div3 ~ #div4 ~ #div5", "els => els.length") == 1
  end

  test "SE-019 should work with +", %{page: page} do
    Page.set_content!(page, """
      <section>
        <div id=div1></div>
        <div id=div2></div>
        <div id=div3></div>
        <div id=div4></div>
        <div id=div5></div>
        <div id=div6></div>
      </section>
    """)

    ids = "els => els.map(e => e.id)"
    assert Page.eval_on_selector_all!(page, "#div1 >> :scope+div", ids) == ["div2"]
    assert Page.eval_on_selector_all!(page, "#div1 >> :scope+*", ids) == ["div2"]
    assert Page.eval_on_selector_all!(page, "#div1 >> + div", ids) == ["div2"]
    assert Page.eval_on_selector_all!(page, "#div1 >> + *", ids) == ["div2"]
    assert Page.eval_on_selector_all!(page, "#div3 >> div + :scope", ids) == ["div3"]
    assert Page.eval_on_selector_all!(page, "#div3 >> #div1 + :scope", ids) == []
    assert Page.eval_on_selector_all!(page, "css=#div1 ~ div + #div6", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=#div1 ~ div + div", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "css=#div3 + div + div", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=#div4 ~ #div5 + div", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=#div5 + div + div", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=#div3 ~ #div2 + #div6", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=#div3 + #div4 + #div5", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=div + #div1", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=section > div + div ~ div", "els => els.length") == 4
    assert Page.eval_on_selector_all!(page, "css=section > div + #div4 ~ div", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "css=section:has(:scope > div + #div2)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=section:has(:scope > div + #div1)", "els => els.length") == 0
    assert Page.eval_on_selector!(page, "css=div:has(:scope + #div5)", "e => e.id") == "div4"
  end

  test "SE-020 should work with spaces in :nth-child and :not", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(23n +2)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span:nth-child(23n+ 2)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span:nth-child( 23n + 2 )", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span:not(#root1 #target)", "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, "css=span:not(:not(#root1 #target))", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span:not(span:not(#root1 #target))", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=div > :not(span)", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "css=body :not(span, div)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=span, section:not(span, div)", "els => els.length") == 5
    assert Page.eval_on_selector_all!(page, "span:nth-child(23n+ 2) >> xpath=.", "els => els.length") == 1
  end

  test "SE-021 should work with :is", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector_all!(page, "css=div:is(#root1)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=div:is(#root1, #target)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "css=div:is(span, #target)", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=div:is(span, #root1 > *)", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "css=div:is(section div)", "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, "css=:is(div, span)", "els => els.length") == 7
    assert Page.eval_on_selector_all!(page, "css=section:is(section) div:is(section div)", "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, "css=:is(div, span) > *", "els => els.length") == 6
    assert Page.eval_on_selector_all!(page, "css=#root1:has(:is(#root1))", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=#root1:has(:is(:scope, #root1))", "els => els.length") == 1
  end

  test "SE-022 should work with :has", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector_all!(page, "css=div:has(#target)", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "css=div:has([data-testid=foo])", "els => els.length") == 3
    assert Page.eval_on_selector_all!(page, "css=div:has([attr*=value])", "els => els.length") == 2

    Page.set_content!(page, "<section><span></span><div></div></section><section><br></section>")
    assert Page.eval_on_selector_all!(page, "section:has(span, div)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "section:has(span, div)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "section:has(br)", "els => els.length") == 1
    assert Page.eval_on_selector_all!(page, "section:has(span, br)", "els => els.length") == 2
    assert Page.eval_on_selector_all!(page, "section:has(span, br, div)", "els => els.length") == 2
  end

  test "SE-023 should work with :scope", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    # 'is' does not change the scope, so it remains 'html'.
    assert Page.eval_on_selector_all!(page, "css=div:is(:scope#root1)", "els => els.length") == 0
    assert Page.eval_on_selector_all!(page, "css=div:is(:scope #root1)", "els => els.length") == 1
    # 'has' does change the scope, so it becomes the 'div' we are querying.
    assert Page.eval_on_selector_all!(page, "css=div:has(:scope > #target)", "els => els.length") == 1

    handle = Page.query_selector!(page, "css=span")

    for eval_on_selector_all <- [
          &Page.eval_on_selector_all!(page, &1, &2),
          &ElementHandle.eval_on_selector_all!(handle, &1, &2)
        ] do
      assert eval_on_selector_all.("css=:scope", "els => els.length") == 1
      assert eval_on_selector_all.("css=* :scope", "els => els.length") == 0
      assert eval_on_selector_all.("css=* + :scope", "els => els.length") == 0
      assert eval_on_selector_all.("css=* > :scope", "els => els.length") == 0
      assert eval_on_selector_all.("css=* ~ :scope", "els => els.length") == 0
    end

    Page.set_content!(page, "<article><div class=target>hello<span></span></div></article>")
    # 'scope' should allow additional native css modifiers
    assert Page.eval_on_selector!(page, "div >> :scope.target", "e => e.textContent") == "hello"
    assert Page.eval_on_selector!(page, "div >> :scope:nth-child(1)", "e => e.textContent") == "hello"
    assert Page.eval_on_selector!(page, "div >> :scope.target:has(span)", "e => e.textContent") == "hello"
    assert Page.eval_on_selector!(page, "html:scope", "e => e.nodeName") == "HTML"

    Page.set_content!(page, "<section><span id=span1><span id=inner></span></span><span id=span2></span></section>")
    ids = "els => els.map(e => e.id)"
    assert Page.eval_on_selector_all!(page, "#span1 >> span:not(:has(:scope > div))", ids) == ["inner"]
    assert Page.eval_on_selector_all!(page, "#span1 >> #inner,:scope", ids) == ["span1", "inner"]
    assert Page.eval_on_selector_all!(page, "#span1 >> span,:scope", ids) == ["span1", "inner"]
    assert Page.eval_on_selector_all!(page, "#span1 >> span:not(:scope)", ids) == ["inner"]
    # Upstream to-do: the following two do not work. We do not expand the context for the inner :scope,
    # because we should only expand for one clause of :is() that contains :scope, but not the other.
    # expect(await page.$$eval(`#span1 >> span:is(:scope)`, els => els.map(e => e.id))).toEqual(['span1']);
    # expect(await page.$$eval(`#span1 >> span:is(:scope,#inner)`, els => els.map(e => e.id))).toEqual(['span1', 'inner']);
  end

  test "SE-024 should work with :scope and class", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/17824' });
    Page.set_content!(page, """
    <div class="apple"></div>
                             <div class="apple selected"></div>
    """)

    apples = Page.locator(page, ".apple")
    selected_apples = Locator.locator(apples, ":scope.selected")
    Expect.to_have_count!(selected_apples, 1)
  end

  test "SE-025 should absolutize relative selectors", %{page: page} do
    Page.set_content!(page, "<div><span>Hi</span></div>")
    assert Page.eval_on_selector!(page, "div >> >span", "e => e.textContent") == "Hi"
    assert Locator.text_content!(Locator.locator(Page.locator(page, "div"), ">span")) == "Hi"
    assert Page.eval_on_selector!(page, "div:has(> span)", "e => e.outerHTML") == "<div><span>Hi</span></div>"
    assert Page.query_selector!(page, "div:has(> div)") == nil
  end

  test "SE-026 css on the handle should be relative", %{page: page} do
    Page.set_content!(page, """
      <span class="find-me" id=target1>1</span>
      <div>
        <span class="find-me" id=target2>2</span>
      </div>
    """)

    assert Page.eval_on_selector!(page, ".find-me", "e => e.id") == "target1"

    div = Page.query_selector!(page, "div")
    assert ElementHandle.eval_on_selector!(div, ".find-me", "e => e.id") == "target2"
    assert Page.eval_on_selector!(page, "div >> .find-me", "e => e.id") == "target2"
  end

  test "SE-027 should use light DOM structure for child combinator with slotted content", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/37768' }
    Page.set_content!(page, """
      <my-button>
        <template shadowrootmode="open">
          <button><slot></slot></button>
        </template>
        <div class="content">Foo</div>
      </my-button>
    """)

    assert Page.eval_on_selector!(page, "my-button > div", "e => e.className") == "content"
    assert Page.eval_on_selector!(page, "my-button > .content", "e => e.textContent") == "Foo"
  end
end
