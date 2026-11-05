defmodule PlaywrightEx.Page.SelectorsTextTest do
  @upstream "tests/page/selectors-text.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  defp outer_html(page, selector), do: Page.eval_on_selector!(page, selector, "e => e.outerHTML")
  defp id(page, selector), do: Page.eval_on_selector!(page, selector, "e => e.id")
  defp count(page, selector), do: Page.eval_on_selector_all!(page, selector, "els => els.length")

  test "should work @smoke", %{page: page} do
    Page.set_content!(page, "<div>yo</div><div>ya</div><div>\nye  </div>")
    assert outer_html(page, "text=ya") == "<div>ya</div>"
    assert outer_html(page, ~s{text="ya"}) == "<div>ya</div>"
    assert outer_html(page, "text=/^[ay]+$/") == "<div>ya</div>"
    assert outer_html(page, "text=/Ya/i") == "<div>ya</div>"
    assert outer_html(page, "text=ye") == "<div>\nye  </div>"
    assert Locator.evaluate!(Page.get_by_text(page, "ye"), "e => e.outerHTML") =~ ">\nye  </div>"

    Page.set_content!(page, "<div> ye </div><div>ye</div>")
    assert outer_html(page, ~s{text="ye"}) == "<div> ye </div>"

    assert page |> Page.get_by_text("ye", exact: true) |> Locator.first() |> Locator.evaluate!("e => e.outerHTML") =~
             "> ye </div>"

    Page.set_content!(page, ~s{<div>yo</div><div>"ya</div><div> hello world! </div>})
    assert outer_html(page, ~S{text="\"ya"}) == ~s{<div>"ya</div>}
    assert outer_html(page, "text=/hello/") == "<div> hello world! </div>"
    assert outer_html(page, ~S{text=/^\s*heLLo/i}) == "<div> hello world! </div>"

    Page.set_content!(page, "<div>yo<div>ya</div>hey<div>hey</div></div>")
    assert outer_html(page, "text=hey") == "<div>hey</div>"
    assert outer_html(page, ~s{text=yo>>text="ya"}) == "<div>ya</div>"
    assert outer_html(page, ~s{text=yo>> text="ya"}) == "<div>ya</div>"
    assert outer_html(page, "text=yo >>text='ya'") == "<div>ya</div>"
    assert outer_html(page, "text=yo >> text='ya'") == "<div>ya</div>"
    assert outer_html(page, ~s{'yo'>>"ya"}) == "<div>ya</div>"
    assert outer_html(page, ~s{"yo" >> 'ya'}) == "<div>ya</div>"

    Page.set_content!(
      page,
      ~s{<div>yo<span id="s1"></span></div><div>yo<span id="s2"></span><span id="s3"></span></div>}
    )

    assert Page.eval_on_selector_all!(page, "text=yo", ~S{es => es.map(e => e.outerHTML).join('\n')}) ==
             ~s{<div>yo<span id="s1"></span></div>\n<div>yo<span id="s2"></span><span id="s3"></span></div>}

    Page.set_content!(page, ~S{<div>'</div><div>"</div><div>\</div><div>x</div>})
    assert outer_html(page, ~S{text='\''}) == "<div>'</div>"
    assert outer_html(page, ~s{text='"'}) == ~s{<div>"</div>}
    assert outer_html(page, ~S{text="\""}) == ~s{<div>"</div>}
    assert outer_html(page, ~s{text="'"}) == "<div>'</div>"
    assert outer_html(page, ~S{text="\x"}) == "<div>x</div>"
    assert outer_html(page, ~S{text='\x'}) == "<div>x</div>"
    assert outer_html(page, ~S{text='\\'}) == ~S{<div>\</div>}
    assert outer_html(page, ~S{text="\\"}) == ~S{<div>\</div>}
    assert outer_html(page, ~s{text="}) == ~s{<div>"</div>}
    assert outer_html(page, "text='") == "<div>'</div>"
    assert outer_html(page, ~s{"x"}) == "<div>x</div>"
    assert outer_html(page, "'x'") == "<div>x</div>"
    assert {:error, %{}} = Page.query_selector(page, ~s{"})
    assert {:error, %{}} = Page.query_selector(page, "'")

    Page.set_content!(page, ~s{<div> ' </div><div> " </div>})
    assert outer_html(page, ~s{text="}) == ~s{<div> " </div>}
    assert outer_html(page, "text='") == "<div> ' </div>"

    Page.set_content!(page, "<div>Hi''&gt;&gt;foo=bar</div>")
    assert outer_html(page, ~s{text="Hi''>>foo=bar"}) == "<div>Hi''&gt;&gt;foo=bar</div>"
    Page.set_content!(page, ~s{<div>Hi'"&gt;&gt;foo=bar</div>})
    assert outer_html(page, ~S{text="Hi'\">>foo=bar"}) == ~s{<div>Hi'"&gt;&gt;foo=bar</div>}

    Page.set_content!(page, "<div>Hi&gt;&gt;<span></span></div>")
    assert outer_html(page, ~s{text="Hi>>">>span}) == "<span></span>"
    assert outer_html(page, ~S{text=/Hi\>\>/ >> span}) == "<span></span>"

    Page.set_content!(page, "<div>a<br>b</div><div>a</div>")
    assert outer_html(page, "text=a") == "<div>a<br>b</div>"
    assert outer_html(page, "text=b") == "<div>a<br>b</div>"
    assert outer_html(page, "text=ab") == "<div>a<br>b</div>"
    assert Page.query_selector!(page, "text=abc") == nil
    assert count(page, "text=a") == 2
    assert count(page, "text=b") == 1
    assert count(page, "text=ab") == 1
    assert count(page, "text=abc") == 0

    Page.set_content!(page, "<div></div><span></span>")

    Page.eval_on_selector!(page, "div", """
    div => {
      div.appendChild(document.createTextNode('hello'));
      div.appendChild(document.createTextNode('world'));
    }
    """)

    Page.eval_on_selector!(page, "span", """
    span => {
      span.appendChild(document.createTextNode('hello'));
      span.appendChild(document.createTextNode('world'));
    }
    """)

    assert outer_html(page, "text=lowo") == "<div>helloworld</div>"

    assert Page.eval_on_selector_all!(page, "text=lowo", "els => els.map(e => e.outerHTML).join('')") ==
             "<div>helloworld</div><span>helloworld</span>"

    Page.set_content!(page, "<span>Sign&nbsp;in</span><span>Hello\n \nworld</span>")
    assert outer_html(page, "text=Sign in") == "<span>Sign&nbsp;in</span>"
    assert length(Page.query_selector_all!(page, "text=Sign \tin")) == 1
    assert length(Page.query_selector_all!(page, ~s{text="Sign in"})) == 1
    assert outer_html(page, "text=lo wo") == "<span>Hello\n \nworld</span>"
    assert outer_html(page, ~s{text="Hello world"}) == "<span>Hello\n \nworld</span>"
    assert Page.query_selector!(page, ~s{text="lo wo"}) == nil
    assert length(Page.query_selector_all!(page, "text=lo \nwo")) == 1
    assert Page.query_selector_all!(page, ~s{text="lo \nwo"}) == []

    Page.set_content!(page, "<div>let's<span>hello</span></div>")
    assert outer_html(page, "text=/let's/i >> span") == "<span>hello</span>"
    assert outer_html(page, ~S{text=/let\'s/i >> span}) == "<span>hello</span>"
  end

  test "should work with :text", %{page: page} do
    Page.set_content!(page, "<div>yo</div><div>ya</div><div>\nHELLO   \n world  </div>")
    assert outer_html(page, ~s{:text("ya")}) == "<div>ya</div>"
    assert outer_html(page, ~s{:text-is("ya")}) == "<div>ya</div>"
    assert outer_html(page, ~s{:text("y")}) == "<div>yo</div>"
    assert Page.query_selector!(page, ~s{:text-is("Y")}) == nil
    assert outer_html(page, ~s{:text("hello world")}) == "<div>\nHELLO   \n world  </div>"
    assert outer_html(page, ~s{:text-is("HELLO world")}) == "<div>\nHELLO   \n world  </div>"
    assert outer_html(page, ~s{:text("lo wo")}) == "<div>\nHELLO   \n world  </div>"
    assert Page.query_selector!(page, ~s{:text-is("lo wo")}) == nil
    assert outer_html(page, ~s{:text-matches("^[ay]+$")}) == "<div>ya</div>"
    assert outer_html(page, ~s{:text-matches("y", "g")}) == "<div>yo</div>"
    assert outer_html(page, ~s{:text-matches("Y", "i")}) == "<div>yo</div>"
    assert Page.query_selector!(page, ~s{:text-matches("^y$")}) == nil

    {:error, error1} = Page.query_selector(page, ~s{:text("foo", "bar")})
    assert Exception.message(error1) =~ ~s{"text" engine expects a single string}
    {:error, error2} = Page.query_selector(page, ":text(foo > bar)")
    assert Exception.message(error2) =~ ~s{"text" engine expects a single string}
  end

  test "should support empty string", %{page: page} do
    Page.set_content!(page, "<div></div><div>ya</div><div>\nHELLO   \n world  </div>")
    assert outer_html(page, ~s{div:text-is("")}) == "<div></div>"
    assert count(page, ~s{div:text-is("")}) == 1
    assert outer_html(page, ~s{div:text("")}) == "<div></div>"
    assert count(page, ~s{div:text("")}) == 3
    assert outer_html(page, ~s{div >> text=""}) == "<div></div>"
    assert count(page, ~s{div >> text=""}) == 1
    assert outer_html(page, "div >> text=/^$/") == "<div></div>"
    assert count(page, "div >> text=/^$/") == 1
    assert outer_html(page, ~s{div:text-matches("")}) == "<div></div>"
    assert count(page, ~s{div:text-matches("")}) == 3
  end

  test "should work across nodes", %{page: page} do
    Page.set_content!(page, "<div id=target1>Hello<i>,</i> <span id=target2>world</span><b>!</b></div>")

    assert id(page, ~s{:text("Hello, world!")}) == "target1"
    assert id(page, ~s{:text("Hello")}) == "target1"
    assert id(page, ~s{:text("world")}) == "target2"
    assert count(page, ~s{:text("world")}) == 1
    assert Page.query_selector!(page, ~s{:text("hello world")}) == nil
    assert Page.query_selector!(page, ~s{div:text("world")}) == nil
    assert id(page, "text=Hello, world!") == "target1"
    assert id(page, "text=Hello") == "target1"
    assert id(page, "text=world") == "target2"
    assert count(page, "text=world") == 1
    assert Page.query_selector!(page, "text=hello world") == nil

    assert Page.query_selector!(page, ~s{:text-is("Hello, world!")}) == nil
    assert id(page, ~s{:text-is("Hello")}) == "target1"
    assert id(page, ~s{:text-is("world")}) == "target2"
    assert count(page, ~s{:text-is("world")}) == 1
    assert Page.query_selector!(page, ~s{text="Hello, world!"}) == nil
    assert id(page, ~s{text="Hello"}) == "target1"
    assert id(page, ~s{text="world"}) == "target2"
    assert count(page, ~s{text="world"}) == 1

    assert Page.eval_on_selector!(page, ~s{:text-matches(".*")}, "e => e.nodeName") == "I"
    assert id(page, ~s{:text-matches("world?")}) == "target2"
    assert count(page, ~s{:text-matches("world")}) == 1
    assert Page.query_selector!(page, ~s{div:text(".*")}) == nil
    assert Page.eval_on_selector!(page, "text=/.*/", "e => e.nodeName") == "I"
    assert id(page, "text=/world?/") == "target2"
    assert count(page, "text=/world/") == 1
  end

  # https://github.com/microsoft/playwright/issues/33976
  test "text-is() should ignore comments", %{page: page} do
    Page.set_content!(page, "<div id=me>hel<!-- comment -->lo\n  <!-- comment -->\n  world</div>")
    assert id(page, ~s{:text-is("hello world")}) == "me"
    assert Locator.get_attribute!(Page.locator(page, "div", has_text: "hello world"), "id") == "me"
    assert Locator.get_attribute!(Page.get_by_text(page, "hello world", exact: true), "id") == "me"
  end

  test "should work with text nodes in quoted mode", %{page: page} do
    Page.set_content!(page, "<div id=target1>Hello<span id=target2>wo  rld  </span>  Hi again  </div>")
    assert id(page, ~s{text="Hello"}) == "target1"
    assert id(page, ~s{text="Hi again"}) == "target1"
    assert id(page, ~s{text="wo rld"}) == "target2"
    assert Page.query_selector!(page, ~s{text="Hellowo rld Hi again"}) == nil
    assert Page.query_selector!(page, ~s{text="Hellowo"}) == nil
    assert Page.query_selector!(page, ~s{text="Hellowo rld"}) == nil
    assert Page.query_selector!(page, ~s{text="wo rld Hi ag"}) == nil
    assert Page.query_selector!(page, ~s{text="again"}) == nil
    assert Page.query_selector!(page, ~s{text="hi again"}) == nil
    assert id(page, "text=hi again") == "target1"
  end

  test "should clear caches", %{page: page} do
    Page.set_content!(page, "<div id=target1>text</div><div id=target2>text</div>")
    div = Page.query_selector!(page, "#target1")

    JSHandle.evaluate!(div, "div => div.textContent = 'text'")
    assert id(page, "text=text") == "target1"
    JSHandle.evaluate!(div, "div => div.textContent = 'foo'")
    assert id(page, "text=text") == "target2"

    JSHandle.evaluate!(div, "div => div.textContent = 'text'")
    assert id(page, ~s{:text("text")}) == "target1"
    JSHandle.evaluate!(div, "div => div.textContent = 'foo'")
    assert id(page, ~s{:text("text")}) == "target2"

    JSHandle.evaluate!(div, "div => div.textContent = 'text'")
    assert count(page, "text=text") == 2
    JSHandle.evaluate!(div, "div => div.textContent = 'foo'")
    assert count(page, "text=text") == 1

    JSHandle.evaluate!(div, "div => div.textContent = 'text'")
    assert count(page, ~s{:text("text")}) == 2
    JSHandle.evaluate!(div, "div => div.textContent = 'foo'")
    assert count(page, ~s{:text("text")}) == 1
  end

  test "should work with :has-text", %{page: page} do
    Page.set_content!(page, """
    <input id=input2>
    <div id=div1>
      <span>  Find me  </span>
      or
      <wrap><span id=span2>maybe me  </span></wrap>
      <div><input id=input1></div>
    </div>
    """)

    assert Page.eval_on_selector!(page, ~s{:has-text("find me")}, "e => e.tagName") == "HTML"
    assert outer_html(page, ~s{span:has-text("find me")}) == "<span>  Find me  </span>"
    assert id(page, ~s{div:has-text("find me")}) == "div1"
    assert id(page, ~s{div:has-text("find me") input}) == "input1"
    assert id(page, ~s{:has-text("find me") input}) == "input2"
    assert id(page, ~s{div:has-text("find me or maybe me")}) == "div1"
    assert Page.query_selector!(page, ~s{div:has-text("find noone")}) == nil

    assert Page.eval_on_selector_all!(page, ~s{:is(div,span):has-text("maybe")}, "els => els.map(e => e.id).join(';')") ==
             "div1;span2"

    assert Page.eval_on_selector!(page, ~s{div:has-text("find me") :has-text("maybe me")}, "e => e.tagName") == "WRAP"
    assert id(page, ~s{div:has-text("find me") span:has-text("maybe me")}) == "span2"

    Page.set_content!(page, ~s{<div id=me>hello\n  wo"r>>ld</div>})
    assert id(page, ~S{div:has-text("hello wo\"r>>ld")}) == "me"
    assert id(page, ~S{div:has-text("hello\a wo\"r>>ld")}) == "me"
    assert Locator.get_attribute!(Page.locator(page, "div", has_text: ~s{hello\nwo"r>>ld}), "id") == "me"

    {:error, error1} = Page.query_selector(page, ~s{:has-text("foo", "bar")})
    assert Exception.message(error1) =~ ~s{"has-text" engine expects a single string}
    {:error, error2} = Page.query_selector(page, ":has-text(foo > bar)")
    assert Exception.message(error2) =~ ~s{"has-text" engine expects a single string}
  end

  test "should work with large DOM", %{page: page} do
    Page.evaluate!(page, """
    () => {
      let id = 0;
      const next = (tag) => {
        const e = document.createElement(tag);
        const eid = ++id;
        e.textContent = 'id' + eid;
        e.id = 'id' + eid;
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
      ~s{:has-text("id18")},
      ~s{:has-text("id12345")},
      ~s{:has-text("id")},
      ~s{:text("id18")},
      ~s{:text("id12345")},
      ~s{:text("id")},
      ~s{:text-matches("id12345", "i")},
      "text=id18",
      "text=id12345",
      "text=id",
      "#id18",
      "#id12345",
      "*"
    ]

    # Upstream's `measure` is false: one iteration each, no timing output.
    for selector <- selectors do
      count(page, selector)
    end
  end

  test "should be case sensitive if quotes are specified", %{page: page} do
    Page.set_content!(page, "<div>yo</div><div>ya</div><div>\nye  </div>")
    assert outer_html(page, "text=yA") == "<div>ya</div>"
    assert Page.query_selector!(page, ~s{text="yA"}) == nil
    assert Page.query_selector!(page, ~s{text= "ya"}) == nil
  end

  test "should search for a substring without quotes", %{page: page} do
    Page.set_content!(page, "<div>textwithsubstring</div>")
    assert outer_html(page, "text=with") == "<div>textwithsubstring</div>"
    assert Page.query_selector!(page, ~s{text="with"}) == nil
  end

  test "should skip head, script and style", %{page: page} do
    Page.set_content!(page, """
    <head>
      <title>title</title>
      <script>var script</script>
      <style>.style {}</style>
    </head>
    <body>
      <script>var script</script>
      <style>.style {}</style>
      <div>title script style</div>
    </body>
    """)

    head = Page.query_selector!(page, "head")
    title = Page.query_selector!(page, "title")
    script = Page.query_selector!(page, "body script")
    style = Page.query_selector!(page, "body style")

    for text <- ["title", "script", "style"] do
      assert Page.eval_on_selector!(page, "text=#{text}", "e => e.nodeName") == "DIV"
      assert Page.eval_on_selector_all!(page, "text=#{text}", "els => els.map(e => e.nodeName).join('|')") == "DIV"

      for root <- [head, title, script, style] do
        assert ElementHandle.query_selector!(root, "text=#{text}") == nil
        assert ElementHandle.eval_on_selector_all!(root, "text=#{text}", "els => els.length") == 0
      end
    end
  end

  test "should match input[type=button|submit|reset]", %{page: page} do
    Page.set_content!(
      page,
      ~s{<input type="submit" value="hello"><input type="button" value="world"><input type="reset" value="clear">}
    )

    assert outer_html(page, "text=hello") == ~s{<input type="submit" value="hello">}
    assert outer_html(page, "text=world") == ~s{<input type="button" value="world">}
    assert outer_html(page, "text=clear") == ~s{<input type="reset" value="clear">}
  end

  test "should work for open shadow roots", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/deep-shadow.html")
    assert Page.eval_on_selector!(page, "text=root1", "e => e.textContent") == "Hello from root1"
    assert Page.eval_on_selector!(page, "text=root2", "e => e.textContent") == "Hello from root2"
    assert Page.eval_on_selector!(page, "text=root3", "e => e.textContent") == "Hello from root3"
    assert Page.eval_on_selector!(page, "#root1 >> text=from root3", "e => e.textContent") == "Hello from root3"
    assert Page.eval_on_selector!(page, "#target >> text=from root2", "e => e.textContent") == "Hello from root2"
    assert Page.query_selector!(page, "text:light=root1") == nil
    assert Page.query_selector!(page, "text:light=root2") == nil
    assert Page.query_selector!(page, "text:light=root3") == nil
  end

  test "should prioritize light dom over shadow dom in the same parent", %{page: page} do
    Page.evaluate!(page, """
    () => {
      const div = document.createElement('div');
      document.body.appendChild(div);

      div.attachShadow({ mode: 'open' });
      const shadowSpan = document.createElement('span');
      shadowSpan.textContent = 'Hello from shadow';
      div.shadowRoot.appendChild(shadowSpan);

      const lightSpan = document.createElement('span');
      lightSpan.textContent = 'Hello from light';
      div.appendChild(lightSpan);
    }
    """)

    assert Page.eval_on_selector!(page, "div >> text=Hello", "e => e.textContent") == "Hello from light"
  end

  test "should waitForSelector with distributed elements", %{page: page} do
    promise = Task.async(fn -> Page.wait_for_selector!(page, "div >> text=Hello") end)

    Page.evaluate!(page, """
    () => {
      const div = document.createElement('div');
      document.body.appendChild(div);

      div.attachShadow({ mode: 'open' });
      const shadowSpan = document.createElement('span');
      shadowSpan.textContent = 'Hello from shadow';
      div.shadowRoot.appendChild(shadowSpan);
      div.shadowRoot.appendChild(document.createElement('slot'));

      const lightSpan = document.createElement('span');
      lightSpan.textContent = 'Hello from light';
      div.appendChild(lightSpan);
    }
    """)

    handle = Task.await(promise, :infinity)
    assert ElementHandle.text_content!(handle) == "Hello from light"
  end

  test "should match root after >>", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    element = Page.query_selector!(page, "css=section >> text=test")
    assert element
    element2 = Page.query_selector!(page, "text=test >> text=test")
    assert element2
  end

  test "should match root after >> with *", %{page: page} do
    Page.set_content!(page, "<button> hello world </button> <button> hellow <span> world </span> </button>")
    assert count(page, "*css=button >> text=hello >> text=world") == 2
  end

  test "should work with leading and trailing spaces", %{page: page} do
    # https://github.com/microsoft/playwright/issues/10997
    Page.set_content!(page, "<button> Add widget </button>")
    Expect.to_be_visible!(Page.locator(page, "text=Add widget"))
    Expect.to_be_visible!(Page.locator(page, "text= Add widget "))
  end

  test "should work with unpaired quotes when not at the start", %{page: page} do
    # https://github.com/microsoft/playwright/issues/12719
    Page.set_content!(page, """
    <div>hello"world<span>yay</span></div>
    <div>hello'world<span>nay</span></div>
    <div>hello`world<span>oh</span></div>
    <div>hello`world<span>oh2</span></div>
    """)

    assert outer_html(page, ~s{text=lo" >> span}) == "<span>yay</span>"
    assert outer_html(page, ~s{  text=lo" >> span}) == "<span>yay</span>"
    assert outer_html(page, ~s{text  =lo" >> span}) == "<span>yay</span>"
    assert outer_html(page, ~s{text=  lo" >> span}) == "<span>yay</span>"
    assert outer_html(page, ~s{ text = lo" >> span}) == "<span>yay</span>"
    assert outer_html(page, ~s{text=o"wor >> span}) == "<span>yay</span>"

    assert outer_html(page, "text=lo'wor >> span") == "<span>nay</span>"
    assert outer_html(page, "text=o' >> span") == "<span>nay</span>"

    assert outer_html(page, "text=ello`wor >> span") == "<span>oh</span>"
    Expect.to_have_text!(page |> Page.locator("text=ello`wor") |> Locator.locator("span") |> Locator.first(), "oh")
    Expect.to_have_text!(page |> Page.locator("text=ello`wor") |> Locator.locator("span") |> Locator.nth(1), "oh2")

    assert Page.query_selector!(page, "text='wor >> span") == nil
    assert Page.query_selector!(page, ~s{text=" >> span}) == nil
    assert Page.query_selector!(page, "text=` >> span") == nil
  end

  test "should work with paired quotes in the middle of selector", %{page: page} do
    # https://github.com/microsoft/playwright/issues/16858
    Page.set_content!(page, ~S{<div>pattern "^-?\d+$"</div>})
    # Upstream wraps these in a bare `expect(...)` without a matcher: no assertion.
    Locator.is_visible!(Page.locator(page, ~S{div >> text=pattern "^-?\d+$}))
    Locator.is_visible!(Page.locator(page, ~S{div >> text=pattern "^-?\d+$"}))
    # Should double escape inside quoted text.
    Locator.is_visible!(Page.locator(page, ~S{div >> text='pattern "^-?\\d+$"'}))
    Expect.to_be_visible!(Page.locator(page, ~S{div >> text=pattern "^-?\d+$}))
    Expect.to_be_visible!(Page.locator(page, ~S{div >> text=pattern "^-?\d+$"}))
    # Should double escape inside quoted text.
    Expect.to_be_visible!(Page.locator(page, ~S{div >> text='pattern "^-?\\d+$"'}))
  end

  test "hasText and internal:text should match full node text in strict mode", %{page: page} do
    Page.set_content!(page, """
    <div id=div1>hello<span>world</span></div>
    <div id=div2>hello</div>
    """)

    Expect.to_have_id!(Page.get_by_text(page, "helloworld", exact: true), "div1")
    Expect.to_have_id!(Page.get_by_text(page, "hello", exact: true), "div2")
    Expect.to_have_id!(Page.locator(page, "div", has_text: ~r/^helloworld$/), "div1")
    Expect.to_have_id!(Page.locator(page, "div", has_text: ~r/^hello$/), "div2")

    Page.set_content!(page, """
    <div id=div1><span id=span1>hello</span>world</div>
    <div id=div2><span id=span2>hello</span></div>
    """)

    Expect.to_have_id!(Page.get_by_text(page, "helloworld", exact: true), "div1")

    assert Locator.evaluate_all!(Page.get_by_text(page, "hello", exact: true), "els => els.map(e => e.id)") == [
             "span1",
             "span2"
           ]

    Expect.to_have_id!(Page.locator(page, "div", has_text: ~r/^helloworld$/), "div1")
    Expect.to_have_id!(Page.locator(page, "div", has_text: ~r/^hello$/), "div2")
  end
end
