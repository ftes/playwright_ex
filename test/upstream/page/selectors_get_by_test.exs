defmodule PlaywrightEx.Page.SelectorsGetByTest do
  @upstream "tests/page/selectors-get-by.spec.ts"
  # Not async: `selectors.setTestIdAttribute` sets the client's global test id attribute (module
  # state in JS), which would leak into `getByTestId` of concurrently running modules.
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Selectors

  @moduletag :page

  # Upstream's `testIdAttribute` fixture sets it to `data-testid` for each test's context.
  defp set_test_id_attribute(playwright, attribute_name) do
    selectors = Playwright.selectors(playwright)
    Selectors.set_test_id_attribute(selectors, attribute_name)
    on_exit(fn -> Selectors.set_test_id_attribute(selectors, "data-testid") end)
  end

  test "getByTestId should work", %{page: page} do
    Page.set_content!(page, ~s(<div><div data-testid="Hello">Hello world</div></div>))
    Expect.to_have_text!(Page.get_by_test_id(page, "Hello"), "Hello world")
    Expect.to_have_text!(Frame.get_by_test_id(Page.main_frame(page), "Hello"), "Hello world")
    Expect.to_have_text!(Locator.get_by_test_id(Page.locator(page, "div"), "Hello"), "Hello world")
  end

  test "getByTestId with custom testId should work", %{page: page, playwright: playwright} do
    Page.set_content!(page, ~s(<div><div data-my-custom-testid="Hello">Hello world</div></div>))
    set_test_id_attribute(playwright, "data-my-custom-testid")
    Expect.to_have_text!(Page.get_by_test_id(page, "Hello"), "Hello world")
    Expect.to_have_text!(Frame.get_by_test_id(Page.main_frame(page), "Hello"), "Hello world")
    Expect.to_have_text!(Locator.get_by_test_id(Page.locator(page, "div"), "Hello"), "Hello world")
  end

  test "getByTestId with comma-separated testIdAttributes should match any", %{page: page, playwright: playwright} do
    Page.set_content!(page, """
      <section>
        <div data-pw="Hello">first</div>
        <div data-ti="Hello">second</div>
        <div data-testid="Hello">third</div>
      </section>
    """)

    set_test_id_attribute(playwright, "data-pw,data-ti")
    Expect.to_have_count!(Page.get_by_test_id(page, "Hello"), 2)
    Expect.to_have_text!(Page.get_by_test_id(page, "Hello"), ["first", "second"])
    Expect.to_have_count!(Frame.get_by_test_id(Page.main_frame(page), "Hello"), 2)
    Expect.to_have_count!(Locator.get_by_test_id(Page.locator(page, "section"), "Hello"), 2)
  end

  test "getByTestId should escape id", %{page: page} do
    Page.set_content!(page, ~s(<div><div data-testid='He"llo'>Hello world</div></div>))
    Expect.to_have_text!(Page.get_by_test_id(page, ~s(He"llo)), "Hello world")
  end

  test "getByTestId should work for regex", %{page: page} do
    Page.set_content!(page, ~s(<div><div data-testid="Hello">Hello world</div></div>))
    Expect.to_have_text!(Page.get_by_test_id(page, ~r/He[l]*o/), "Hello world")
    Expect.to_have_text!(Frame.get_by_test_id(Page.main_frame(page), "Hello"), "Hello world")
    Expect.to_have_text!(Locator.get_by_test_id(Page.locator(page, "div"), "Hello"), "Hello world")
  end

  test "getByText should work", %{page: page} do
    Page.set_content!(page, "<div>yo</div><div>ya</div><div>\nye  </div>")
    assert Locator.evaluate!(Page.get_by_text(page, "ye"), "e => e.outerHTML") =~ ">\nye  </div>"
    assert Locator.evaluate!(Page.get_by_text(page, ~r/ye/), "e => e.outerHTML") =~ ">\nye  </div>"
    assert Locator.evaluate!(Page.get_by_text(page, ~r/e/), "e => e.outerHTML") =~ ">\nye  </div>"

    Page.set_content!(page, "<div> ye </div><div>ye</div>")

    assert Locator.evaluate!(Locator.first(Page.get_by_text(page, "ye", exact: true)), "e => e.outerHTML") =~
             "> ye </div>"

    Page.set_content!(page, "<div>Hello world</div><div>Hello</div>")
    assert Locator.evaluate!(Page.get_by_text(page, "Hello", exact: true), "e => e.outerHTML") =~ ">Hello</div>"
  end

  test "getByLabel should work", %{page: page} do
    Page.set_content!(page, "<div><label for=target>Name</label><input id=target type=text></div>")
    assert Locator.evaluate!(Page.get_by_text(page, "Name"), "e => e.nodeName") == "LABEL"
    assert Locator.evaluate!(Page.get_by_label(page, "Name"), "e => e.nodeName") == "INPUT"
    assert Locator.evaluate!(Frame.get_by_label(Page.main_frame(page), "Name"), "e => e.nodeName") == "INPUT"
    assert Locator.evaluate!(Locator.get_by_label(Page.locator(page, "div"), "Name"), "e => e.nodeName") == "INPUT"
  end

  test "getByLabel should work with nested elements", %{page: page} do
    Page.set_content!(page, "<label for=target>Last <span>Name</span></label><input id=target type=text>")

    Expect.to_have_attribute!(Page.get_by_label(page, "last name"), "id", "target")
    Expect.to_have_attribute!(Page.get_by_label(page, "st na"), "id", "target")
    Expect.to_have_attribute!(Page.get_by_label(page, "Name"), "id", "target")
    Expect.to_have_attribute!(Page.get_by_label(page, "Last Name", exact: true), "id", "target")
    Expect.to_have_attribute!(Page.get_by_label(page, ~r/Last\s+name/i), "id", "target")

    assert Locator.element_handles!(Page.get_by_label(page, "Last", exact: true)) == []
    assert Locator.element_handles!(Page.get_by_label(page, "last name", exact: true)) == []
    assert Locator.element_handles!(Page.get_by_label(page, "Name", exact: true)) == []
    assert Locator.element_handles!(Page.get_by_label(page, "what?")) == []
    assert Locator.element_handles!(Page.get_by_label(page, ~r/last name/)) == []
  end

  test "getByLabel should work with multiply-labelled input", %{page: page} do
    Page.set_content!(
      page,
      "<label for=target>Name</label><input id=target type=text><label for=target>First or Last</label>"
    )

    assert Locator.evaluate!(Page.get_by_label(page, "Name"), "e => e.id") == "target"
    assert Locator.evaluate!(Page.get_by_label(page, "First or Last"), "e => e.id") == "target"
  end

  test "getByLabel should work with ancestor label and multiple controls", %{page: page} do
    Page.set_content!(page, "<label>Name<button id=target>Click me</button><input type=text></label>")
    assert Locator.evaluate!(Page.get_by_label(page, "Name"), "e => e.id") == "target"
  end

  test "getByLabel should work with ancestor label and for", %{page: page} do
    Page.set_content!(page, """
      <label for=target>Name<input type=text id=nontarget></label>
      <input type=text id=target>
    """)

    assert Locator.evaluate!(Page.get_by_label(page, "Name"), "e => e.id") == "target"
  end

  test "getByLabel should work with aria-labelledby", %{page: page} do
    Page.set_content!(page, "<label id=name-label>Name</label><button aria-labelledby=name-label>Click me</button>")
    assert Locator.evaluate!(Page.get_by_label(page, "Name"), "e => e.textContent") == "Click me"
  end

  test "getByLabel should prioritize aria-labelledby over native label", %{page: page} do
    Page.set_content!(page, """
      <label id=name-label>Name</label>
      <label>Wrong<button aria-labelledby=name-label>Click me</button></label>
    """)

    assert Locator.evaluate!(Page.get_by_label(page, "Name"), "e => e.textContent") == "Click me"
  end

  test "getByLabel should work with aria-label", %{page: page} do
    Page.set_content!(page, ~s(<input id=target aria-label="Name">))
    assert Locator.evaluate!(Page.get_by_label(page, "Name"), "e => e.id") == "target"
  end

  test "getByLabel should ignore empty aria-label", %{page: page} do
    Page.set_content!(page, "<label for=target>Last Name</label><input id=target type=text aria-label>")
    assert Locator.evaluate!(Page.get_by_label(page, "Last Name"), "e => e.id") == "target"
  end

  test "getByLabel should prioritize aria-labelledby over aria-label", %{page: page} do
    Page.set_content!(
      page,
      ~s(<label id=other-label>Other</label><input id=target aria-label="Name" aria-labelledby=other-label>)
    )

    assert Locator.evaluate!(Page.get_by_label(page, "Other"), "e => e.id") == "target"
  end

  test "getByPlaceholder should work", %{page: page} do
    Page.set_content!(page, """
    <div>
      <input placeholder='Hello'>
      <input placeholder='Hello World'>
    </div>
    """)

    Expect.to_have_count!(Page.get_by_placeholder(page, "hello"), 2)
    Expect.to_have_count!(Page.get_by_placeholder(page, "Hello", exact: true), 1)
    Expect.to_have_count!(Page.get_by_placeholder(page, ~r/wor/i), 1)

    # Coverage
    Expect.to_have_count!(Frame.get_by_placeholder(Page.main_frame(page), "hello"), 2)
    Expect.to_have_count!(Locator.get_by_placeholder(Page.locator(page, "div"), "hello"), 2)
  end

  test "getByAltText should work", %{page: page} do
    Page.set_content!(page, """
    <div>
      <input alt='Hello'>
      <input alt='Hello World'>
    </div>
    """)

    Expect.to_have_count!(Page.get_by_alt_text(page, "hello"), 2)
    Expect.to_have_count!(Page.get_by_alt_text(page, "Hello", exact: true), 1)
    Expect.to_have_count!(Page.get_by_alt_text(page, ~r/wor/i), 1)

    # Coverage
    Expect.to_have_count!(Frame.get_by_alt_text(Page.main_frame(page), "hello"), 2)
    Expect.to_have_count!(Locator.get_by_alt_text(Page.locator(page, "div"), "hello"), 2)
  end

  test "getByTitle should work", %{page: page} do
    Page.set_content!(page, """
    <div>
      <input title='Hello'>
      <input title='Hello World'>
    </div>
    """)

    Expect.to_have_count!(Page.get_by_title(page, "hello"), 2)
    Expect.to_have_count!(Page.get_by_title(page, "Hello", exact: true), 1)
    Expect.to_have_count!(Page.get_by_title(page, ~r/wor/i), 1)

    # Coverage
    Expect.to_have_count!(Frame.get_by_title(Page.main_frame(page), "hello"), 2)
    Expect.to_have_count!(Locator.get_by_title(Page.locator(page, "div"), "hello"), 2)
  end

  test "getBy escaping", %{page: page} do
    # expect.soft: the bang form (the first failure ends the test).
    Page.set_content!(page, """
    <label id=label for=control>Hello my
    wo"rld</label><input id=control />
    """)

    Page.eval_on_selector!(page, "input", """
    input => {
      input.setAttribute('placeholder', 'hello my\\nwo"rld');
      input.setAttribute('title', 'hello my\\nwo"rld');
      input.setAttribute('alt', 'hello my\\nwo"rld');
    }
    """)

    Expect.to_have_attribute!(Page.get_by_text(page, "hello my\nwo\"rld"), "id", "label")
    Expect.to_have_attribute!(Page.get_by_text(page, "hello       my     wo\"rld"), "id", "label")
    Expect.to_have_attribute!(Page.get_by_label(page, "hello my\nwo\"rld"), "id", "control")
    Expect.to_have_attribute!(Page.get_by_placeholder(page, "hello my\nwo\"rld"), "id", "control")
    Expect.to_have_attribute!(Page.get_by_alt_text(page, "hello my\nwo\"rld"), "id", "control")
    Expect.to_have_attribute!(Page.get_by_title(page, "hello my\nwo\"rld"), "id", "control")

    Page.set_content!(page, """
    <label id=label for=control>Hello my
    world</label><input id=control />
    """)

    Page.eval_on_selector!(page, "input", """
    input => {
      input.setAttribute('placeholder', 'hello my\\nworld');
      input.setAttribute('title', 'hello my\\nworld');
      input.setAttribute('alt', 'hello my\\nworld');
    }
    """)

    Expect.to_have_attribute!(Page.get_by_text(page, "hello my\nworld"), "id", "label")
    Expect.to_have_attribute!(Page.get_by_text(page, "hello        my    world"), "id", "label")
    Expect.to_have_attribute!(Page.get_by_label(page, "hello my\nworld"), "id", "control")
    Expect.to_have_attribute!(Page.get_by_placeholder(page, "hello my\nworld"), "id", "control")
    Expect.to_have_attribute!(Page.get_by_alt_text(page, "hello my\nworld"), "id", "control")
    Expect.to_have_attribute!(Page.get_by_title(page, "hello my\nworld"), "id", "control")

    Page.set_content!(page, ~s(<div id=target title="my title">Text here</div>))
    Expect.to_have_count!(Page.get_by_title(page, "my title", exact: true), 1, timeout: 500)
    # JS 'my t\itle' is "my title" (a useless escape).
    Expect.to_have_count!(Page.get_by_title(page, "my title", exact: true), 1, timeout: 500)
    Expect.to_have_count!(Page.get_by_title(page, "my t\\itle", exact: true), 0, timeout: 500)
    # JS 'my t\\\itle' is "my t\\itle".
    Expect.to_have_count!(Page.get_by_title(page, "my t\\itle", exact: true), 0, timeout: 500)
    Expect.to_have_count!(Page.get_by_title(page, "my t\\\\itle", exact: true), 0, timeout: 500)

    Page.set_content!(page, "<label for=target>foo &gt;&gt; bar</label><input id=target>")

    Page.eval_on_selector!(page, "input", """
    input => {
      input.setAttribute('placeholder', 'foo >> bar');
      input.setAttribute('title', 'foo >> bar');
      input.setAttribute('alt', 'foo >> bar');
    }
    """)

    assert Locator.text_content!(Page.get_by_text(page, "foo >> bar")) == "foo >> bar"
    Expect.to_have_text!(Page.locator(page, "label"), "foo >> bar")
    Expect.to_have_text!(Page.get_by_text(page, "foo >> bar"), "foo >> bar")
    assert Locator.text_content!(Page.get_by_text(page, ~r/foo >> bar/)) == "foo >> bar"
    Expect.to_have_attribute!(Page.get_by_label(page, "foo >> bar"), "id", "target")
    Expect.to_have_attribute!(Page.get_by_label(page, ~r/foo >> bar/), "id", "target")
    Expect.to_have_attribute!(Page.get_by_placeholder(page, "foo >> bar"), "id", "target")
    Expect.to_have_attribute!(Page.get_by_alt_text(page, "foo >> bar"), "id", "target")
    Expect.to_have_attribute!(Page.get_by_title(page, "foo >> bar"), "id", "target")
    Expect.to_have_attribute!(Page.get_by_placeholder(page, ~r/foo >> bar/), "id", "target")
    Expect.to_have_attribute!(Page.get_by_alt_text(page, ~r/foo >> bar/), "id", "target")
    Expect.to_have_attribute!(Page.get_by_title(page, ~r/foo >> bar/), "id", "target")
  end

  @outer_html "els => els.map(e => e.outerHTML)"

  test "getByRole escaping", %{page: page} do
    Page.set_content!(page, """
      <a href="https://playwright.dev">issues 123</a>
      <a href="https://playwright.dev">he llo 56</a>
      <button>Click me</button>
    """)

    assert Locator.evaluate_all!(Page.get_by_role(page, :button), @outer_html) == [
             "<button>Click me</button>"
           ]

    assert Locator.evaluate_all!(Page.get_by_role(page, :link), @outer_html) == [
             ~s(<a href="https://playwright.dev">issues 123</a>),
             ~s(<a href="https://playwright.dev">he llo 56</a>)
           ]

    assert Locator.evaluate_all!(Page.get_by_role(page, :link, name: "issues 123"), @outer_html) == [
             ~s(<a href="https://playwright.dev">issues 123</a>)
           ]

    assert Locator.evaluate_all!(Page.get_by_role(page, :link, name: "sues"), @outer_html) == [
             ~s(<a href="https://playwright.dev">issues 123</a>)
           ]

    assert Locator.evaluate_all!(Page.get_by_role(page, :link, name: "  he    \n  llo "), @outer_html) == [
             ~s(<a href="https://playwright.dev">he llo 56</a>)
           ]

    assert Locator.evaluate_all!(Page.get_by_role(page, :button, name: "issues"), @outer_html) == []

    assert Locator.evaluate_all!(Page.get_by_role(page, :link, name: "sues", exact: true), @outer_html) == []

    assert Locator.evaluate_all!(Page.get_by_role(page, :link, name: "   he \n llo 56 ", exact: true), @outer_html) ==
             [~s(<a href="https://playwright.dev">he llo 56</a>)]

    assert Locator.evaluate_all!(Page.get_by_role(page, :button, name: "Click me", exact: true), @outer_html) == [
             "<button>Click me</button>"
           ]

    # JS 'Click \me' is "Click me" (a useless escape).
    assert Locator.evaluate_all!(Page.get_by_role(page, :button, name: "Click me", exact: true), @outer_html) == [
             "<button>Click me</button>"
           ]

    assert Locator.evaluate_all!(Page.get_by_role(page, :button, name: "Click \\me", exact: true), @outer_html) == []
    # JS 'Click \\\me' is "Click \\me".
    assert Locator.evaluate_all!(Page.get_by_role(page, :button, name: "Click \\me", exact: true), @outer_html) == []
    assert Locator.evaluate_all!(Page.get_by_role(page, :button, name: "Click \\\\me", exact: true), @outer_html) == []
  end

  test "getByRole should accept regexp with v flag"

  @text_content "els => els.map(e => e.textContent)"

  test "getByRole with description", %{page: page} do
    Page.set_content!(page, """
      <div role="alert" aria-label="Upload successful" aria-description="File doc-2025.pdf was uploaded successfully">Alert 1</div>
      <div role="alert" aria-label="Upload successful" aria-description="File report-2026.pdf was uploaded successfully">Alert 2</div>
      <div role="alert" aria-label="Invalid file" aria-description="File demo.doc has an invalid file format">Alert 3</div>
    """)

    # description substring match (default)
    assert Locator.evaluate_all!(Page.get_by_role(page, :alert, description: "doc-2025"), @text_content) == ["Alert 1"]

    assert Locator.evaluate_all!(Page.get_by_role(page, :alert, description: "report-2026"), @text_content) == [
             "Alert 2"
           ]

    # description with name combined
    assert Locator.evaluate_all!(
             Page.get_by_role(page, :alert, name: "Upload successful", description: "doc-2025"),
             @text_content
           ) == ["Alert 1"]

    assert Locator.evaluate_all!(
             Page.get_by_role(page, :alert, name: "Upload successful", description: "report-2026"),
             @text_content
           ) == ["Alert 2"]

    assert Locator.evaluate_all!(
             Page.get_by_role(page, :alert, name: "Invalid file", description: "doc-2025"),
             @text_content
           ) == []

    # description exact match
    assert Locator.evaluate_all!(Page.get_by_role(page, :alert, description: "doc-2025", exact: true), @text_content) ==
             []

    assert Locator.evaluate_all!(
             Page.get_by_role(page, :alert, description: "File doc-2025.pdf was uploaded successfully", exact: true),
             @text_content
           ) == ["Alert 1"]

    # description regex match
    assert Locator.evaluate_all!(Page.get_by_role(page, :alert, description: ~r/report-\d+/), @text_content) == [
             "Alert 2"
           ]

    assert Locator.evaluate_all!(Page.get_by_role(page, :alert, description: ~r/uploaded successfully$/), @text_content) ==
             ["Alert 1", "Alert 2"]
  end

  test "getByRole with description via aria-describedby", %{page: page} do
    Page.set_content!(page, """
      <button aria-describedby="desc1">Submit</button>
      <span id="desc1">Submits the form data</span>
      <button aria-describedby="desc2">Submit</button>
      <span id="desc2">Saves as draft</span>
    """)

    assert Locator.evaluate_all!(
             Page.get_by_role(page, :button, name: "Submit", description: "form data"),
             @text_content
           ) == ["Submit"]

    assert Locator.evaluate_all!(Page.get_by_role(page, :button, name: "Submit", description: "draft"), @text_content) ==
             ["Submit"]
  end

  test "getByRole with description via title fallback", %{page: page} do
    Page.set_content!(page, """
      <button title="Submits the form">Submit</button>
      <button title="Resets the form">Reset</button>
    """)

    assert Locator.evaluate_all!(Page.get_by_role(page, :button, description: "Submits"), @text_content) == ["Submit"]
    assert Locator.evaluate_all!(Page.get_by_role(page, :button, description: "Resets"), @text_content) == ["Reset"]
  end

  test "getByRole with description whitespace normalization", %{page: page} do
    Page.set_content!(page, """
      <div role="alert" aria-description="File  doc-2025.pdf   was uploaded   successfully">Alert</div>
    """)

    assert Locator.evaluate_all!(
             Page.get_by_role(page, :alert, description: "  doc-2025.pdf \n was  uploaded "),
             @text_content
           ) == ["Alert"]
  end

  test "locators should not be affected by global and sticky regex flags"
end
