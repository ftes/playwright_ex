defmodule PlaywrightEx.Page.LocatorQueryTest do
  @upstream "tests/page/locator-query.spec.ts"
  # isolate: registers a selector engine on the driver.
  use PlaywrightEx.UpstreamCase, async: true, isolate: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Selectors

  @moduletag :page

  test "LO-157 should respect first() and last() @smoke", %{page: page} do
    Page.set_content!(page, """
    <section>
      <div><p>A</p></div>
      <div><p>A</p><p>A</p></div>
      <div><p>A</p><p>A</p><p>A</p></div>
    </section>
    """)

    assert Locator.count!(Page.locator(page, "div >> p")) == 6
    assert Locator.count!(Locator.locator(Page.locator(page, "div"), "p")) == 6
    assert Locator.count!(Locator.locator(Locator.first(Page.locator(page, "div")), "p")) == 1
    assert Locator.count!(Locator.locator(Locator.last(Page.locator(page, "div")), "p")) == 3
  end

  test "LO-158 should respect nth()", %{page: page} do
    Page.set_content!(page, """
    <section>
      <div><p>A</p></div>
      <div><p>A</p><p>A</p></div>
      <div><p>A</p><p>A</p><p>A</p></div>
    </section>
    """)

    assert Locator.count!(Locator.nth(Page.locator(page, "div >> p"), 0)) == 1
    assert Locator.count!(Locator.locator(Locator.nth(Page.locator(page, "div"), 1), "p")) == 2
    assert Locator.count!(Locator.locator(Locator.nth(Page.locator(page, "div"), 2), "p")) == 3
  end

  test "LO-159 should throw on capture w/ nth()", %{page: page} do
    Page.set_content!(page, "<section><div><p>A</p></div></section>")
    {:error, e} = Locator.click(Locator.nth(Page.locator(page, "*css=div >> p"), 1))
    assert Exception.message(e) =~ "Can't query n-th element"
  end

  test "LO-160 should throw on due to strictness", %{page: page} do
    Page.set_content!(page, "<div>A</div><div>B</div>")
    {:error, e} = Locator.is_visible(Page.locator(page, "div"))
    assert Exception.message(e) =~ "strict mode violation"
  end

  test "LO-161 should throw on due to strictness 2", %{page: page} do
    Page.set_content!(page, "<select><option>One</option><option>Two</option></select>")
    {:error, e} = Locator.evaluate(Page.locator(page, "option"), "e => {}")
    assert Exception.message(e) =~ "strict mode violation"
  end

  test "LO-162 should filter by text", %{page: page} do
    Page.set_content!(page, "<div>Foobar</div><div>Bar</div>")
    Expect.to_have_text!(Page.locator(page, "div", has_text: "Foo"), "Foobar")
  end

  test "LO-163 should filter by text 2", %{page: page} do
    Page.set_content!(page, "<div>foo <span>hello world</span> bar</div>")
    Expect.to_have_text!(Page.locator(page, "div", has_text: "hello world"), "foo hello world bar")
  end

  test "LO-164 should filter by regex", %{page: page} do
    Page.set_content!(page, "<div>Foobar</div><div>Bar</div>")
    Expect.to_have_text!(Page.locator(page, "div", has_text: ~r/Foo.*/), "Foobar")
  end

  test "LO-165 should filter by text with quotes", %{page: page} do
    Page.set_content!(page, ~s|<div>Hello "world"</div><div>Hello world</div>|)
    Expect.to_have_text!(Page.locator(page, "div", has_text: ~s|Hello "world"|), ~s|Hello "world"|)
  end

  test "LO-166 should filter by regex with quotes", %{page: page} do
    Page.set_content!(page, ~s|<div>Hello "world"</div><div>Hello world</div>|)
    Expect.to_have_text!(Page.locator(page, "div", has_text: ~r/Hello "world"/), ~s|Hello "world"|)
  end

  # expect.soft: the first failure fails the test here.
  test "LO-167 should filter by regex with a single quote", %{page: page} do
    Page.set_content!(page, "<button>let's let's<span>hello</span></button>")
    by_text = fn re -> Page.locator(page, "button", has_text: re) end
    by_role = fn re -> Page.get_by_role(page, :button, name: re) end
    span = fn locator -> Locator.locator(locator, "span") end

    Expect.to_have_text!(span.(by_text.(~r/let's/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let's/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/let\'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let\'s/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/'s/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/\'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/\'s/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/let['abc]s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let['abc]s/i)), "hello")
    Expect.not_to_be_visible!(by_text.(~r/let\\'s/i))
    Expect.not_to_be_visible!(by_role.(~r/let\\'s/i))
    Expect.to_have_text!(span.(by_text.(~r/let's let\'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let's let\'s/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/let\'s let's/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let\'s let's/i)), "hello")

    Page.set_content!(page, "<button>let\\'s let\\'s<span>hello</span></button>")
    Expect.not_to_be_visible!(by_text.(~r/let\'s/i))
    Expect.not_to_be_visible!(by_role.(~r/let\'s/i))
    Expect.to_have_text!(span.(by_text.(~r/let\\'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let\\'s/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/let\\\'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let\\\'s/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/let\\'s let\\\'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let\\'s let\\\'s/i)), "hello")
    Expect.to_have_text!(span.(by_text.(~r/let\\\'s let\\'s/i)), "hello")
    Expect.to_have_text!(span.(by_role.(~r/let\\\'s let\\'s/i)), "hello")

    Page.set_content!(page, "<button>let's hello</button>")
    Expect.to_have_text!(by_text.(~r/let's/iu), "let's hello")
    Expect.to_have_text!(by_role.(~r/let's/iu), "let's hello")
  end

  test "LO-168 should filter by regex and regexp flags", %{page: page} do
    Page.set_content!(page, ~s|<div>Hello "world"</div><div>Hello world</div>|)
    Expect.to_have_text!(Page.locator(page, "div", has_text: ~r/hElLo "world"/i), ~s|Hello "world"|)
  end

  test "LO-169 should filter by case-insensitive regex in a child", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/15348' });
    Page.set_content!(page, ~s|<div class="test"><h5>Title Text</h5></div>|)
    Expect.to_have_text!(Page.locator(page, "div", has_text: ~r/^title text$/i), "Title Text")
  end

  test "LO-170 should filter by case-insensitive regex in multiple children", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/15348' });
    Page.set_content!(page, ~s|<div class="test"><h5>Title</h5> <h2><i>Text</i></h2></div>|)
    Expect.to_have_class!(Page.locator(page, "div", has_text: ~r/^title text$/i), "test")
  end

  test "LO-171 should filter by regex with special symbols", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/15348' });
    Page.set_content!(page, ~s|<div class="test"><h5>First/"and"</h5><h2><i>Second\\</i></h2></div>|)
    Expect.to_have_class!(Page.locator(page, "div", has_text: ~r/^first\/".*"second\\$/si), "test")
  end

  # it.skip(trace === 'on')  -- tracing is not on in these tests
  test "LO-172 should support has:locator", %{page: page} do
    Page.set_content!(page, "<div><span>hello</span></div><div><span>world</span></div>")
    Expect.to_have_count!(Page.locator(page, "div", has: Page.locator(page, "text=world")), 1)

    assert Locator.evaluate!(Page.locator(page, "div", has: Page.locator(page, "text=world")), "e => e.outerHTML") ==
             "<div><span>world</span></div>"

    Expect.to_have_count!(Page.locator(page, "div", has: Page.locator(page, ~s|text="hello"|)), 1)

    assert Locator.evaluate!(Page.locator(page, "div", has: Page.locator(page, ~s|text="hello"|)), "e => e.outerHTML") ==
             "<div><span>hello</span></div>"

    Expect.to_have_count!(Page.locator(page, "div", has: Page.locator(page, "xpath=./span")), 2)
    Expect.to_have_count!(Page.locator(page, "div", has: Page.locator(page, "span")), 2)
    Expect.to_have_count!(Page.locator(page, "div", has: Page.locator(page, "span", has_text: "wor")), 1)

    assert Locator.evaluate!(
             Page.locator(page, "div", has: Page.locator(page, "span", has_text: "wor")),
             "e => e.outerHTML"
           ) == "<div><span>world</span></div>"

    Expect.to_have_count!(Page.locator(page, "div", has: Page.locator(page, "span"), has_text: "wor"), 1)
  end

  # it.skip(trace === 'on')  -- tracing is not on in these tests
  test "LO-173 should support locator.filter", %{page: page} do
    Page.set_content!(page, "<section><div><span>hello</span></div><div><span>world</span></div></section>")
    div = Page.locator(page, "div")
    Expect.to_have_count!(Locator.filter(div, has_text: "hello"), 1)
    Expect.to_have_count!(Locator.filter(Page.locator(page, "div", has_text: "hello"), has_text: "hello"), 1)
    Expect.to_have_count!(Locator.filter(Page.locator(page, "div", has_text: "hello"), has_text: "world"), 0)
    Expect.to_have_count!(Locator.filter(Page.locator(page, "section", has_text: "hello"), has_text: "world"), 1)
    Expect.to_have_count!(Locator.locator(Locator.filter(div, has_text: "hello"), "span"), 1)
    Expect.to_have_count!(Locator.filter(div, has: Page.locator(page, "span", has_text: "world")), 1)
    Expect.to_have_count!(Locator.filter(div, has: Page.locator(page, "span")), 2)
    Expect.to_have_count!(Locator.filter(div, has: Page.locator(page, "span"), has_text: "world"), 1)
    Expect.to_have_count!(Locator.filter(div, has_not: Page.locator(page, "span", has_text: "world")), 1)
    Expect.to_have_count!(Locator.filter(div, has_not: Page.locator(page, "section")), 2)
    Expect.to_have_count!(Locator.filter(div, has_not: Page.locator(page, "span")), 0)
    Expect.to_have_count!(Locator.filter(div, has_not_text: "hello"), 1)
    Expect.to_have_count!(Locator.filter(div, has_not_text: "foo"), 2)
  end

  test "LO-174 should support locator.and", %{page: page} do
    Page.set_content!(page, """
      <div data-testid=foo>hello</div><div data-testid=bar>world</div>
      <span data-testid=foo>hello2</span><span data-testid=bar>world2</span>
    """)

    Expect.to_have_count!(Locator.and_(Page.locator(page, "div"), Page.locator(page, "div")), 2)
    Expect.to_have_text!(Locator.and_(Page.locator(page, "div"), Page.get_by_test_id(page, "foo")), ["hello"])
    Expect.to_have_text!(Locator.and_(Page.locator(page, "div"), Page.get_by_test_id(page, "bar")), ["world"])
    Expect.to_have_text!(Locator.and_(Page.get_by_test_id(page, "foo"), Page.locator(page, "div")), ["hello"])
    Expect.to_have_text!(Locator.and_(Page.get_by_test_id(page, "bar"), Page.locator(page, "span")), ["world2"])
    Expect.to_have_count!(Locator.and_(Page.locator(page, "span"), Page.get_by_test_id(page, ~r/bar|foo/)), 2)
  end

  test "LO-175 should support locator.or", %{page: page} do
    Page.set_content!(page, "<div>hello</div><span>world</span>")
    loc = &Page.locator(page, &1)
    Expect.to_have_count!(Locator.or_(loc.("div"), loc.("span")), 2)
    Expect.to_have_text!(Locator.or_(loc.("div"), loc.("span")), ["hello", "world"])
    Expect.to_have_text!(Locator.or_(Locator.or_(loc.("span"), loc.("article")), loc.("div")), ["hello", "world"])
    Expect.to_have_count!(Locator.or_(loc.("article"), loc.("something")), 0)
    Expect.to_have_text!(Locator.or_(loc.("article"), loc.("div")), "hello")
    Expect.to_have_text!(Locator.or_(loc.("article"), loc.("span")), "world")
    Expect.to_have_text!(Locator.or_(loc.("div"), loc.("article")), "hello")
    Expect.to_have_text!(Locator.or_(loc.("span"), loc.("article")), "world")
  end

  test "LO-176 should support locator.locator with and/or", %{page: page} do
    Page.set_content!(page, """
      <div>one <span>two</span> <button>three</button> </div>
      <span>four</span>
      <button>five</button>
    """)

    loc = &Page.locator(page, &1)
    Expect.to_have_text!(Locator.locator(loc.("div"), loc.("button")), ["three"])
    Expect.to_have_text!(Locator.locator(loc.("div"), Locator.or_(loc.("button"), loc.("span"))), ["two", "three"])
    Expect.to_have_text!(Locator.or_(loc.("button"), loc.("span")), ["two", "three", "four", "five"])

    Expect.to_have_text!(
      Locator.locator(loc.("div"), Locator.and_(loc.("button"), Page.get_by_role(page, :button))),
      ["three"]
    )

    Expect.to_have_text!(Locator.and_(loc.("button"), Page.get_by_role(page, :button)), ["three", "five"])
  end

  test "LO-177 should support locator.within", %{page: page} do
    Page.set_content!(page, """
      <table>
        <tr><td>a1</td><td>a2</td><td>a3</td></tr>
        <tr><td>b1</td><td>b2</td><td>b3</td></tr>
        <tr><td>c1</td><td>c2</td><td>c3</td></tr>
      </table>
      <span>outside</span>
    """)

    cell = Page.get_by_role(page, :cell)
    row = Page.get_by_role(page, :row)

    Expect.to_have_text!(Locator.within(cell, row), ["a1", "a2", "a3", "b1", "b2", "b3", "c1", "c2", "c3"])
    Expect.to_have_text!(Locator.within(Locator.nth(cell, 1), row), ["a2", "b2", "c2"])
    Expect.to_have_text!(Locator.within(Locator.last(cell), row), ["a3", "b3", "c3"])
    Expect.to_have_text!(Locator.within(Locator.nth(cell, 1), Locator.nth(row, 2)), ["c2"])
    Expect.to_have_count!(Locator.within(Page.locator(page, "span"), row), 0)
    Expect.to_have_text!(Locator.nth(Locator.within(Locator.nth(cell, 1), row), 1), "b2")
  end

  test "LO-178 should allow some, but not all nested frameLocators", %{page: page} do
    Page.set_content!(page, ~s|<iframe srcdoc="<span id=target>world</span>"></iframe><span>hello</span>|)
    fl = fn selector, inner -> FrameLocator.locator(Page.frame_locator(page, selector), inner) end

    Expect.to_have_text!(Locator.or_(fl.("iframe", "span"), fl.("iframe", "article")), "world")
    Expect.to_have_text!(Locator.or_(fl.("iframe", "article"), fl.("iframe", "span")), "world")
    Expect.to_have_text!(Locator.and_(fl.("iframe", "span"), fl.("iframe", "#target")), "world")
    {:error, error1} = Expect.to_have_text(Locator.or_(fl.("iframe", "div"), fl.("#iframe", "span")), "world")

    assert Exception.message(error1) =~
             ~s|Frame locators are not allowed inside composite locators, while querying "locator('iframe').contentFrame().locator('div').or(locator('#iframe').contentFrame().locator('span'))|

    {:error, error2} = Expect.to_have_text(Locator.and_(fl.("iframe", "div"), fl.("#iframe", "span")), "world")

    assert Exception.message(error2) =~
             ~s|Frame locators are not allowed inside composite locators, while querying "locator('iframe').contentFrame().locator('div').and(locator('#iframe').contentFrame().locator('span'))|
  end

  test "LO-179 should keep the capture when removing a common frame prefix", %{page: page} do
    Page.set_content!(page, ~s|<iframe id=f srcdoc="<section id=target><span>hi</span></section>"></iframe>|)
    inner = FrameLocator.locator(Page.frame_locator(page, "#f"), "*css=section >> span")

    Expect.to_have_attribute!(
      Locator.locator(FrameLocator.locator(Page.frame_locator(page, "#f"), "body"), inner),
      "id",
      "target"
    )

    capture_frame = FrameLocator.locator(Locator.content_frame(Page.locator(page, "*css=#f")), "span")

    {:error, error} =
      Locator.count(Locator.locator(FrameLocator.locator(Page.frame_locator(page, "#f"), "body"), capture_frame))

    assert Exception.message(error) =~ "Can not capture the selector before diving into the frame"
  end

  test "LO-180 should enforce same frame for has/leftOf/rightOf/above/below/near", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/two-frames.html")
    child = Enum.at(Page.frames(page), 1)

    for option <- [:has] do
      error =
        try do
          Page.locator(page, "div", [{option, Frame.locator(child, "span")}])
          nil
        rescue
          e -> e
        end

      assert Exception.message(error) =~ ~s|Inner "#{option}" locator must belong to the same frame.|
    end
  end

  test "LO-181 alias methods coverage", %{page: page} do
    Page.set_content!(page, "<div><button>Submit</button></div>")
    Expect.to_have_count!(Page.locator(page, "button"), 1)
    Expect.to_have_count!(Locator.locator(Page.locator(page, "div"), "button"), 1)
    Expect.to_have_count!(Locator.get_by_role(Page.locator(page, "div"), :button), 1)
    Expect.to_have_count!(Frame.locator(Page.main_frame(page), "button"), 1)
  end

  test "LO-182 count() should not throw during navigation", %{playwright: playwright, page: page, server: server} do
    create_dummy_selector = """
    (() => ({
      query(root, selector) {
        window.location.href = './frames/one-frame.html';
        return document.querySelector(selector);
      },
      queryAll(root, selector) {
        window.location.href = './frames/one-frame.html';
        return Array.from(document.querySelectorAll(selector));
      }
    }))()
    """

    Selectors.register!(Playwright.selectors(playwright), "locatorCountHelper", create_dummy_selector)
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    Frame.set_content!(Enum.at(Page.frames(page), 1), "<div>A</div>")

    assert Locator.count!(
             FrameLocator.locator(Page.frame_locator(page, "locatorCountHelper=iframe"), "locatorCountHelper=div")
           ) == 0
  end
end
