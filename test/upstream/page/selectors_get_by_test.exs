defmodule PlaywrightEx.Page.SelectorsGetByTest do
  @upstream "tests/page/selectors-get-by.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  @tag skip: "not ported: expect"
  test "getByTestId should work"

  # Also `playwright.selectors.setTestIdAttribute` (ported), which is global module state as in JS.
  @tag skip: "not ported: expect"
  test "getByTestId with custom testId should work"

  @tag skip: "not ported: expect"
  test "getByTestId with comma-separated testIdAttributes should match any"

  @tag skip: "not ported: expect"
  test "getByTestId should escape id"

  @tag skip: "not ported: expect"
  test "getByTestId should work for regex"

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

  @tag skip: "not ported: expect"
  test "getByLabel should work with nested elements"

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

  @tag skip: "not ported: expect"
  test "getByPlaceholder should work"

  @tag skip: "not ported: expect"
  test "getByAltText should work"

  @tag skip: "not ported: expect"
  test "getByTitle should work"

  @tag skip: "not ported: expect"
  test "getBy escaping"

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

  @tag skip: "not ported: expect"
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

  @tag skip: "not ported: expect"
  test "locators should not be affected by global and sticky regex flags"
end
