defmodule PlaywrightEx.Library.LocatorGeneratorTest do
  @upstream "tests/library/locator-generator.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Isomorphic.LocatorGenerators
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Heap

  @moduletag :page

  # `iso.asLocator`, `iso.asLocators`, `iso.asLocatorDescription`
  defp as_locator(lang, selector), do: LocatorGenerators.as_locator(lang, selector)
  defp as_locators(lang, selector), do: LocatorGenerators.as_locators(lang, selector)
  defp as_locator_description(lang, selector), do: LocatorGenerators.as_locator_description(lang, selector)

  defp generate(locator) do
    generate_for_selector(Map.get(locator, :_selector) || Map.get(locator, :_frameSelector))
  end

  defp generate_for_selector(selector) do
    Map.new(~w(javascript python java csharp), &{&1, as_locator(&1, selector)})
  end

  defp generate_for_node(page_or_frame, target) do
    selector = Locator.evaluate!(Page.locator(page_or_frame, target), "e => window.playwright.selector(e)")
    Map.new(~w(javascript python java csharp), &{&1, as_locator(&1, selector)})
  end

  # `channel.method(params)` on a client handle.
  defp channel_call(owner, method, params) do
    Api.call(nil, owner, fn -> ChannelOwner.channel_call(owner, method, params) end)
  end

  test "reverse engineer locators", %{page: page} do
    assert generate(Page.get_by_test_id(page, "Hello")) == %{
             "javascript" => "getByTestId('Hello')",
             "python" => "get_by_test_id(\"Hello\")",
             "java" => "getByTestId(\"Hello\")",
             "csharp" => "GetByTestId(\"Hello\")"
           }

    assert generate(Page.get_by_test_id(page, "He\"llo")) == %{
             "javascript" => "getByTestId('He\"llo')",
             "python" => "get_by_test_id(\"He\\\"llo\")",
             "java" => "getByTestId(\"He\\\"llo\")",
             "csharp" => "GetByTestId(\"He\\\"llo\")"
           }

    assert generate(Page.get_by_test_id(page, ~r/He"llo/)) == %{
             "javascript" => "getByTestId(/He\"llo/)",
             "python" => "get_by_test_id(re.compile(r\"He\\\"llo\"))",
             "java" => "getByTestId(Pattern.compile(\"He\\\"llo\"))",
             "csharp" => "GetByTestId(new Regex(\"He\\\"llo\"))"
           }

    assert generate(Page.get_by_test_id(page, ~r/He\\"llo/)) == %{
             "javascript" => "getByTestId(/He\\\\\"llo/)",
             "python" => "get_by_test_id(re.compile(r\"He\\\\\\\"llo\"))",
             "java" => "getByTestId(Pattern.compile(\"He\\\\\\\\\\\"llo\"))",
             "csharp" => "GetByTestId(new Regex(\"He\\\\\\\\\\\"llo\"))"
           }

    assert generate(Page.get_by_text(page, "Hello", exact: true)) == %{
             "csharp" => "GetByText(\"Hello\", new() { Exact = true })",
             "java" => "getByText(\"Hello\", new Page.GetByTextOptions().setExact(true))",
             "javascript" => "getByText('Hello', { exact: true })",
             "python" => "get_by_text(\"Hello\", exact=True)"
           }

    assert generate(Page.get_by_text(page, "Hello")) == %{
             "csharp" => "GetByText(\"Hello\")",
             "java" => "getByText(\"Hello\")",
             "javascript" => "getByText('Hello')",
             "python" => "get_by_text(\"Hello\")"
           }

    assert generate(Page.get_by_text(page, ~r/Hello/)) == %{
             "csharp" => "GetByText(new Regex(\"Hello\"))",
             "java" => "getByText(Pattern.compile(\"Hello\"))",
             "javascript" => "getByText(/Hello/)",
             "python" => "get_by_text(re.compile(r\"Hello\"))"
           }

    assert generate(Page.get_by_label(page, "Name")) == %{
             "csharp" => "GetByLabel(\"Name\")",
             "java" => "getByLabel(\"Name\")",
             "javascript" => "getByLabel('Name')",
             "python" => "get_by_label(\"Name\")"
           }

    assert generate(Page.get_by_label(page, "Last Name", exact: true)) == %{
             "csharp" => "GetByLabel(\"Last Name\", new() { Exact = true })",
             "java" => "getByLabel(\"Last Name\", new Page.GetByLabelOptions().setExact(true))",
             "javascript" => "getByLabel('Last Name', { exact: true })",
             "python" => "get_by_label(\"Last Name\", exact=True)"
           }

    assert generate(Page.get_by_label(page, ~r/Last\s+name/i)) == %{
             "csharp" => "GetByLabel(new Regex(\"Last\\\\s+name\", RegexOptions.IgnoreCase))",
             "java" => "getByLabel(Pattern.compile(\"Last\\\\s+name\", Pattern.CASE_INSENSITIVE))",
             "javascript" => "getByLabel(/Last\\s+name/i)",
             "python" => "get_by_label(re.compile(r\"Last\\s+name\", re.IGNORECASE))"
           }

    # Only JavaScript can express these flags, other languages drop them.
    for flags <- ["u", "s", "y", "d", "v", "gm"],
        {engine, method} <- [{"text", "getByText"}, {"label", "getByLabel"}] do
      selector = "internal:#{engine}=/Hello/#{flags}"
      assert as_locator("javascript", selector) == "#{method}(/Hello/#{flags})", selector
    end

    assert generate(Page.get_by_placeholder(page, "hello")) == %{
             "csharp" => "GetByPlaceholder(\"hello\")",
             "java" => "getByPlaceholder(\"hello\")",
             "javascript" => "getByPlaceholder('hello')",
             "python" => "get_by_placeholder(\"hello\")"
           }

    assert generate(Page.get_by_placeholder(page, "Hello", exact: true)) == %{
             "csharp" => "GetByPlaceholder(\"Hello\", new() { Exact = true })",
             "java" => "getByPlaceholder(\"Hello\", new Page.GetByPlaceholderOptions().setExact(true))",
             "javascript" => "getByPlaceholder('Hello', { exact: true })",
             "python" => "get_by_placeholder(\"Hello\", exact=True)"
           }

    assert generate(Page.get_by_placeholder(page, ~r/wor/i)) == %{
             "csharp" => "GetByPlaceholder(new Regex(\"wor\", RegexOptions.IgnoreCase))",
             "java" => "getByPlaceholder(Pattern.compile(\"wor\", Pattern.CASE_INSENSITIVE))",
             "javascript" => "getByPlaceholder(/wor/i)",
             "python" => "get_by_placeholder(re.compile(r\"wor\", re.IGNORECASE))"
           }

    assert generate(Page.get_by_alt_text(page, "hello")) == %{
             "csharp" => "GetByAltText(\"hello\")",
             "java" => "getByAltText(\"hello\")",
             "javascript" => "getByAltText('hello')",
             "python" => "get_by_alt_text(\"hello\")"
           }

    assert generate(Page.get_by_alt_text(page, "Hello", exact: true)) == %{
             "csharp" => "GetByAltText(\"Hello\", new() { Exact = true })",
             "java" => "getByAltText(\"Hello\", new Page.GetByAltTextOptions().setExact(true))",
             "javascript" => "getByAltText('Hello', { exact: true })",
             "python" => "get_by_alt_text(\"Hello\", exact=True)"
           }

    assert generate(Page.get_by_alt_text(page, ~r/wor/i)) == %{
             "csharp" => "GetByAltText(new Regex(\"wor\", RegexOptions.IgnoreCase))",
             "java" => "getByAltText(Pattern.compile(\"wor\", Pattern.CASE_INSENSITIVE))",
             "javascript" => "getByAltText(/wor/i)",
             "python" => "get_by_alt_text(re.compile(r\"wor\", re.IGNORECASE))"
           }

    assert generate(Page.get_by_title(page, "hello")) == %{
             "csharp" => "GetByTitle(\"hello\")",
             "java" => "getByTitle(\"hello\")",
             "javascript" => "getByTitle('hello')",
             "python" => "get_by_title(\"hello\")"
           }

    assert generate(Page.get_by_title(page, "Hello", exact: true)) == %{
             "csharp" => "GetByTitle(\"Hello\", new() { Exact = true })",
             "java" => "getByTitle(\"Hello\", new Page.GetByTitleOptions().setExact(true))",
             "javascript" => "getByTitle('Hello', { exact: true })",
             "python" => "get_by_title(\"Hello\", exact=True)"
           }

    assert generate(Page.get_by_title(page, ~r/wor/i)) == %{
             "csharp" => "GetByTitle(new Regex(\"wor\", RegexOptions.IgnoreCase))",
             "java" => "getByTitle(Pattern.compile(\"wor\", Pattern.CASE_INSENSITIVE))",
             "javascript" => "getByTitle(/wor/i)",
             "python" => "get_by_title(re.compile(r\"wor\", re.IGNORECASE))"
           }

    assert generate(Page.get_by_placeholder(page, "hello my\nwo\"rld")) == %{
             "csharp" => "GetByPlaceholder(\"hello my\\nwo\\\"rld\")",
             "java" => "getByPlaceholder(\"hello my\\nwo\\\"rld\")",
             "javascript" => "getByPlaceholder('hello my\\nwo\"rld')",
             "python" => "get_by_placeholder(\"hello my\\nwo\\\"rld\")"
           }

    assert generate(Page.get_by_alt_text(page, "hello my\nwo\"rld")) == %{
             "csharp" => "GetByAltText(\"hello my\\nwo\\\"rld\")",
             "java" => "getByAltText(\"hello my\\nwo\\\"rld\")",
             "javascript" => "getByAltText('hello my\\nwo\"rld')",
             "python" => "get_by_alt_text(\"hello my\\nwo\\\"rld\")"
           }

    assert generate(Page.get_by_title(page, "hello my\nwo\"rld")) == %{
             "csharp" => "GetByTitle(\"hello my\\nwo\\\"rld\")",
             "java" => "getByTitle(\"hello my\\nwo\\\"rld\")",
             "javascript" => "getByTitle('hello my\\nwo\"rld')",
             "python" => "get_by_title(\"hello my\\nwo\\\"rld\")"
           }
  end

  test "reverse engineer getByRole", %{page: page} do
    assert generate(Page.get_by_role(page, :button)) == %{
             "javascript" => "getByRole('button')",
             "python" => "get_by_role(\"button\")",
             "java" => "getByRole(AriaRole.BUTTON)",
             "csharp" => "GetByRole(AriaRole.Button)"
           }

    assert generate(Page.get_by_role(page, :heading, [])) == %{
             "javascript" => "getByRole('heading')",
             "python" => "get_by_role(\"heading\")",
             "java" => "getByRole(AriaRole.HEADING)",
             "csharp" => "GetByRole(AriaRole.Heading)"
           }

    assert generate(Page.get_by_role(page, :button, name: "Hello")) == %{
             "javascript" => "getByRole('button', { name: 'Hello' })",
             "python" => "get_by_role(\"button\", name=\"Hello\")",
             "java" => "getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName(\"Hello\"))",
             "csharp" => "GetByRole(AriaRole.Button, new() { Name = \"Hello\" })"
           }

    assert generate(Page.get_by_role(page, :button, name: ~r/Hello/)) == %{
             "javascript" => "getByRole('button', { name: /Hello/ })",
             "python" => "get_by_role(\"button\", name=re.compile(r\"Hello\"))",
             "java" => "getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName(Pattern.compile(\"Hello\")))",
             "csharp" => "GetByRole(AriaRole.Button, new() { NameRegex = new Regex(\"Hello\") })"
           }

    assert generate(Page.get_by_role(page, :button, name: "He\"llo", exact: true)) == %{
             "javascript" => "getByRole('button', { name: 'He\"llo', exact: true })",
             "python" => "get_by_role(\"button\", name=\"He\\\"llo\", exact=True)",
             "java" => "getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName(\"He\\\"llo\").setExact(true))",
             "csharp" => "GetByRole(AriaRole.Button, new() { Name = \"He\\\"llo\", Exact = true })"
           }

    assert generate(Page.get_by_role(page, :button, checked: true, pressed: false, level: 3)) == %{
             "javascript" => "getByRole('button', { checked: true, level: 3, pressed: false })",
             "python" => "get_by_role(\"button\", checked=True, level=3, pressed=False)",
             "java" =>
               "getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setChecked(true).setLevel(3).setPressed(false))",
             "csharp" => "GetByRole(AriaRole.Button, new() { Checked = true, Level = 3, Pressed = false })"
           }

    assert generate(Page.get_by_role(page, :alert, name: "Upload", description: "doc.pdf")) == %{
             "javascript" => "getByRole('alert', { name: 'Upload', description: 'doc.pdf' })",
             "python" => "get_by_role(\"alert\", name=\"Upload\", description=\"doc.pdf\")",
             "java" =>
               "getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setName(\"Upload\").setDescription(\"doc.pdf\"))",
             "csharp" => "GetByRole(AriaRole.Alert, new() { Name = \"Upload\", Description = \"doc.pdf\" })"
           }

    assert generate(Page.get_by_role(page, :alert, description: "doc.pdf")) == %{
             "javascript" => "getByRole('alert', { description: 'doc.pdf' })",
             "python" => "get_by_role(\"alert\", description=\"doc.pdf\")",
             "java" => "getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setDescription(\"doc.pdf\"))",
             "csharp" => "GetByRole(AriaRole.Alert, new() { Description = \"doc.pdf\" })"
           }

    assert generate(Page.get_by_role(page, :alert, description: ~r/doc\.pdf/)) == %{
             "javascript" => "getByRole('alert', { description: /doc\\.pdf/ })",
             "python" => "get_by_role(\"alert\", description=re.compile(r\"doc\\.pdf\"))",
             "java" =>
               "getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setDescription(Pattern.compile(\"doc\\\\.pdf\")))",
             "csharp" => "GetByRole(AriaRole.Alert, new() { DescriptionRegex = new Regex(\"doc\\\\.pdf\") })"
           }

    assert generate(Page.get_by_role(page, :alert, name: "Upload", description: "doc.pdf", exact: true)) == %{
             "javascript" => "getByRole('alert', { name: 'Upload', description: 'doc.pdf', exact: true })",
             "python" => "get_by_role(\"alert\", name=\"Upload\", description=\"doc.pdf\", exact=True)",
             "java" =>
               "getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setName(\"Upload\").setDescription(\"doc.pdf\").setExact(true))",
             "csharp" =>
               "GetByRole(AriaRole.Alert, new() { Name = \"Upload\", Description = \"doc.pdf\", Exact = true })"
           }
  end

  test "refuses to translate internal:role with conflicting name/description exactness" do
    conflicting = "internal:role=row[name=\"abc\"i][description=\"d\"s]"
    conflicting_reversed = "internal:role=row[name=\"abc\"s][description=\"d\"i]"

    for lang <- ~w(javascript python java csharp) do
      assert as_locator(lang, conflicting) == conflicting, lang
      assert as_locator(lang, conflicting_reversed) == conflicting_reversed, lang
    end
  end

  test "reverse engineer internal:role with regex and string name/description" do
    assert generate_for_selector("internal:role=alert[name=/Upload/][description=\"doc.pdf\"i]") == %{
             "javascript" => "getByRole('alert', { name: /Upload/, description: 'doc.pdf' })",
             "python" => "get_by_role(\"alert\", name=re.compile(r\"Upload\"), description=\"doc.pdf\")",
             "java" =>
               "getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setName(Pattern.compile(\"Upload\")).setDescription(\"doc.pdf\"))",
             "csharp" =>
               "GetByRole(AriaRole.Alert, new() { NameRegex = new Regex(\"Upload\"), Description = \"doc.pdf\" })"
           }

    assert generate_for_selector("internal:role=alert[name=\"Upload\"i][description=/doc\\.pdf/]") == %{
             "javascript" => "getByRole('alert', { name: 'Upload', description: /doc\\.pdf/ })",
             "python" => "get_by_role(\"alert\", name=\"Upload\", description=re.compile(r\"doc\\.pdf\"))",
             "java" =>
               "getByRole(AriaRole.ALERT, new Page.GetByRoleOptions().setName(\"Upload\").setDescription(Pattern.compile(\"doc\\\\.pdf\")))",
             "csharp" =>
               "GetByRole(AriaRole.Alert, new() { Name = \"Upload\", DescriptionRegex = new Regex(\"doc\\\\.pdf\") })"
           }
  end

  test "reverse engineer ignore-case locators", %{page: page} do
    assert generate(Page.get_by_text(page, "hello my\nwo\"rld")) == %{
             "csharp" => "GetByText(\"hello my\\nwo\\\"rld\")",
             "java" => "getByText(\"hello my\\nwo\\\"rld\")",
             "javascript" => "getByText('hello my\\nwo\"rld')",
             "python" => "get_by_text(\"hello my\\nwo\\\"rld\")"
           }

    assert generate(Page.get_by_text(page, "hello       my     wo\"rld")) == %{
             "csharp" => "GetByText(\"hello       my     wo\\\"rld\")",
             "java" => "getByText(\"hello       my     wo\\\"rld\")",
             "javascript" => "getByText('hello       my     wo\"rld')",
             "python" => "get_by_text(\"hello       my     wo\\\"rld\")"
           }

    assert generate(Page.get_by_label(page, "hello my\nwo\"rld")) == %{
             "csharp" => "GetByLabel(\"hello my\\nwo\\\"rld\")",
             "java" => "getByLabel(\"hello my\\nwo\\\"rld\")",
             "javascript" => "getByLabel('hello my\\nwo\"rld')",
             "python" => "get_by_label(\"hello my\\nwo\\\"rld\")"
           }
  end

  test "reverse engineer ordered locators", %{page: page} do
    assert generate(page |> Page.locator("div") |> Locator.nth(3) |> Locator.first() |> Locator.last()) == %{
             "csharp" => "Locator(\"div\").Nth(3).First.Last",
             "java" => "locator(\"div\").nth(3).first().last()",
             "javascript" => "locator('div').nth(3).first().last()",
             "python" => "locator(\"div\").nth(3).first.last"
           }
  end

  test "reverse engineer locators with regex", %{page: page} do
    assert generate(Page.get_by_text(page, ~r/he\/\sl\nlo/)) == %{
             "csharp" => "GetByText(new Regex(\"he\\\\/\\\\sl\\\\nlo\"))",
             "java" => "getByText(Pattern.compile(\"he\\\\/\\\\sl\\\\nlo\"))",
             "javascript" => "getByText(/he\\/\\sl\\nlo/)",
             "python" => "get_by_text(re.compile(r\"he/\\sl\\nlo\"))"
           }

    assert generate(Page.get_by_placeholder(page, ~r/he\/\sl\nlo/)) == %{
             "csharp" => "GetByPlaceholder(new Regex(\"he\\\\/\\\\sl\\\\nlo\"))",
             "java" => "getByPlaceholder(Pattern.compile(\"he\\\\/\\\\sl\\\\nlo\"))",
             "javascript" => "getByPlaceholder(/he\\/\\sl\\nlo/)",
             "python" => "get_by_placeholder(re.compile(r\"he/\\sl\\nlo\"))"
           }

    assert generate(Page.get_by_text(page, ~r/hel"lo/)) == %{
             "csharp" => "GetByText(new Regex(\"hel\\\"lo\"))",
             "java" => "getByText(Pattern.compile(\"hel\\\"lo\"))",
             "javascript" => "getByText(/hel\"lo/)",
             "python" => "get_by_text(re.compile(r\"hel\\\"lo\"))"
           }

    assert generate(Page.get_by_placeholder(page, ~r/hel"lo/)) == %{
             "csharp" => "GetByPlaceholder(new Regex(\"hel\\\"lo\"))",
             "java" => "getByPlaceholder(Pattern.compile(\"hel\\\"lo\"))",
             "javascript" => "getByPlaceholder(/hel\"lo/)",
             "python" => "get_by_placeholder(re.compile(r\"hel\\\"lo\"))"
           }
  end

  test "reverse engineer hasText", %{page: page} do
    assert generate(page |> Page.get_by_text("Hello") |> Locator.filter(has_text: "wo\"rld\n")) == %{
             "csharp" => "GetByText(\"Hello\").Filter(new() { HasText = \"wo\\\"rld\\n\" })",
             "java" => "getByText(\"Hello\").filter(new Locator.FilterOptions().setHasText(\"wo\\\"rld\\n\"))",
             "javascript" => "getByText('Hello').filter({ hasText: 'wo\"rld\\n' })",
             "python" => "get_by_text(\"Hello\").filter(has_text=\"wo\\\"rld\\n\")"
           }

    assert generate(page |> Page.get_by_text("Hello") |> Locator.filter(has_text: ~r/wo\/\srld\n/)) == %{
             "csharp" => "GetByText(\"Hello\").Filter(new() { HasTextRegex = new Regex(\"wo\\\\/\\\\srld\\\\n\") })",
             "java" =>
               "getByText(\"Hello\").filter(new Locator.FilterOptions().setHasText(Pattern.compile(\"wo\\\\/\\\\srld\\\\n\")))",
             "javascript" => "getByText('Hello').filter({ hasText: /wo\\/\\srld\\n/ })",
             "python" => "get_by_text(\"Hello\").filter(has_text=re.compile(r\"wo/\\srld\\n\"))"
           }

    assert generate(page |> Page.get_by_text("Hello") |> Locator.filter(has_text: ~r/wor"ld/)) == %{
             "csharp" => "GetByText(\"Hello\").Filter(new() { HasTextRegex = new Regex(\"wor\\\"ld\") })",
             "java" =>
               "getByText(\"Hello\").filter(new Locator.FilterOptions().setHasText(Pattern.compile(\"wor\\\"ld\")))",
             "javascript" => "getByText('Hello').filter({ hasText: /wor\"ld/ })",
             "python" => "get_by_text(\"Hello\").filter(has_text=re.compile(r\"wor\\\"ld\"))"
           }
  end

  test "reverse engineer hasNotText", %{page: page} do
    assert generate(page |> Page.get_by_text("Hello") |> Locator.filter(has_not_text: "wo\"rld\n")) == %{
             "csharp" => "GetByText(\"Hello\").Filter(new() { HasNotText = \"wo\\\"rld\\n\" })",
             "java" => "getByText(\"Hello\").filter(new Locator.FilterOptions().setHasNotText(\"wo\\\"rld\\n\"))",
             "javascript" => "getByText('Hello').filter({ hasNotText: 'wo\"rld\\n' })",
             "python" => "get_by_text(\"Hello\").filter(has_not_text=\"wo\\\"rld\\n\")"
           }
  end

  test "reverse engineer visible", %{page: page} do
    assert generate(page |> Page.get_by_text("Hello") |> Locator.visible() |> Locator.locator("div")) == %{
             "csharp" => "GetByText(\"Hello\").Visible.Locator(\"div\")",
             "java" => "getByText(\"Hello\").visible().locator(\"div\")",
             "javascript" => "getByText('Hello').visible().locator('div')",
             "python" => "get_by_text(\"Hello\").visible.locator(\"div\")"
           }

    assert generate(page |> Page.get_by_text("Hello") |> Locator.filter(visible: false) |> Locator.locator("div")) == %{
             "csharp" => "GetByText(\"Hello\").Filter(new() { Visible = false }).Locator(\"div\")",
             "java" => "getByText(\"Hello\").filter(new Locator.FilterOptions().setVisible(false)).locator(\"div\")",
             "javascript" => "getByText('Hello').filter({ visible: false }).locator('div')",
             "python" => "get_by_text(\"Hello\").filter(visible=False).locator(\"div\")"
           }
  end

  test "reverse engineer has", %{page: page} do
    assert generate(
             page
             |> Page.get_by_text("Hello")
             |> Locator.filter(has: page |> Page.locator("div") |> Locator.get_by_text("bye"))
           ) == %{
             "csharp" => "GetByText(\"Hello\").Filter(new() { Has = Locator(\"div\").GetByText(\"bye\") })",
             "java" =>
               "getByText(\"Hello\").filter(new Locator.FilterOptions().setHas(locator(\"div\").getByText(\"bye\")))",
             "javascript" => "getByText('Hello').filter({ has: locator('div').getByText('bye') })",
             "python" => "get_by_text(\"Hello\").filter(has=locator(\"div\").get_by_text(\"bye\"))"
           }

    locator =
      page
      |> Page.locator("section")
      |> Locator.filter(has: page |> Page.locator("div") |> Locator.filter(has: Page.locator(page, "span")))
      |> Locator.filter(has_text: "foo")
      |> Locator.filter(has: Page.locator(page, "a"))

    assert generate(locator) == %{
             "csharp" =>
               "Locator(\"section\").Filter(new() { Has = Locator(\"div\").Filter(new() { Has = Locator(\"span\") }) }).Filter(new() { HasText = \"foo\" }).Filter(new() { Has = Locator(\"a\") })",
             "java" =>
               "locator(\"section\").filter(new Locator.FilterOptions().setHas(locator(\"div\").filter(new Locator.FilterOptions().setHas(locator(\"span\"))))).filter(new Locator.FilterOptions().setHasText(\"foo\")).filter(new Locator.FilterOptions().setHas(locator(\"a\")))",
             "javascript" =>
               "locator('section').filter({ has: locator('div').filter({ has: locator('span') }) }).filter({ hasText: 'foo' }).filter({ has: locator('a') })",
             "python" =>
               "locator(\"section\").filter(has=locator(\"div\").filter(has=locator(\"span\"))).filter(has_text=\"foo\").filter(has=locator(\"a\"))"
           }
  end

  test "reverse engineer hasNot", %{page: page} do
    assert generate(
             page
             |> Page.get_by_text("Hello")
             |> Locator.filter(has_not: page |> Page.locator("div") |> Locator.get_by_text("bye"))
           ) == %{
             "csharp" => "GetByText(\"Hello\").Filter(new() { HasNot = Locator(\"div\").GetByText(\"bye\") })",
             "java" =>
               "getByText(\"Hello\").filter(new Locator.FilterOptions().setHasNot(locator(\"div\").getByText(\"bye\")))",
             "javascript" => "getByText('Hello').filter({ hasNot: locator('div').getByText('bye') })",
             "python" => "get_by_text(\"Hello\").filter(has_not=locator(\"div\").get_by_text(\"bye\"))"
           }

    locator =
      page
      |> Page.locator("section")
      |> Locator.filter(has: page |> Page.locator("div") |> Locator.filter(has_not: Page.locator(page, "span")))
      |> Locator.filter(has_text: "foo")
      |> Locator.filter(has_not: Page.locator(page, "a"))

    assert generate(locator) == %{
             "csharp" =>
               "Locator(\"section\").Filter(new() { Has = Locator(\"div\").Filter(new() { HasNot = Locator(\"span\") }) }).Filter(new() { HasText = \"foo\" }).Filter(new() { HasNot = Locator(\"a\") })",
             "java" =>
               "locator(\"section\").filter(new Locator.FilterOptions().setHas(locator(\"div\").filter(new Locator.FilterOptions().setHasNot(locator(\"span\"))))).filter(new Locator.FilterOptions().setHasText(\"foo\")).filter(new Locator.FilterOptions().setHasNot(locator(\"a\")))",
             "javascript" =>
               "locator('section').filter({ has: locator('div').filter({ hasNot: locator('span') }) }).filter({ hasText: 'foo' }).filter({ hasNot: locator('a') })",
             "python" =>
               "locator(\"section\").filter(has=locator(\"div\").filter(has_not=locator(\"span\"))).filter(has_text=\"foo\").filter(has_not=locator(\"a\"))"
           }
  end

  test "reverse engineer has + hasText", %{page: page} do
    locator =
      page
      |> Page.locator("section")
      |> Locator.filter(has_text: "foo", has: Page.locator(page, "div"))
      |> Locator.locator("a")

    assert generate(locator) == %{
             "csharp" =>
               "Locator(\"section\").Filter(new() { HasText = \"foo\" }).Filter(new() { Has = Locator(\"div\") }).Locator(\"a\")",
             "java" =>
               "locator(\"section\").filter(new Locator.FilterOptions().setHasText(\"foo\")).filter(new Locator.FilterOptions().setHas(locator(\"div\"))).locator(\"a\")",
             "javascript" =>
               "locator('section').filter({ hasText: 'foo' }).filter({ has: locator('div') }).locator('a')",
             "python" => "locator(\"section\").filter(has_text=\"foo\").filter(has=locator(\"div\")).locator(\"a\")"
           }
  end

  test "reverse engineer frameLocator", %{page: page} do
    locator =
      page
      |> Page.frame_locator("iframe")
      |> FrameLocator.get_by_text("foo", exact: true)
      |> Locator.frame_locator("frame")
      |> FrameLocator.first()
      |> FrameLocator.frame_locator("iframe")
      |> FrameLocator.locator("span")

    assert generate(locator) == %{
             "csharp" =>
               "Locator(\"iframe\").ContentFrame.GetByText(\"foo\", new() { Exact = true }).Locator(\"frame\").First.ContentFrame.Locator(\"iframe\").ContentFrame.Locator(\"span\")",
             "java" =>
               "locator(\"iframe\").contentFrame().getByText(\"foo\", new FrameLocator.GetByTextOptions().setExact(true)).locator(\"frame\").first().contentFrame().locator(\"iframe\").contentFrame().locator(\"span\")",
             "javascript" =>
               "locator('iframe').contentFrame().getByText('foo', { exact: true }).locator('frame').first().contentFrame().locator('iframe').contentFrame().locator('span')",
             "python" =>
               "locator(\"iframe\").content_frame.get_by_text(\"foo\", exact=True).locator(\"frame\").first.content_frame.locator(\"iframe\").content_frame.locator(\"span\")"
           }

    # Note that frame locators with ">>" are not restored back due to ambiguity.
    selector = (page |> Page.frame_locator("div >> iframe") |> FrameLocator.locator("span"))._selector
    assert as_locator("javascript", selector) == "locator('div').locator('iframe').contentFrame().locator('span')"

    assert as_locators("javascript", "internal:attr=[title=\"iframe title\"i] >> internal:control=enter-frame") == [
             "getByTitle('iframe title').contentFrame()"
           ]
  end

  test "reverse engineer frameLocator without a selector", %{page: page} do
    assert generate(page |> Page.frame_locator() |> FrameLocator.get_by_text("foo") |> Locator.locator("span")) == %{
             "csharp" => "FrameLocator().GetByText(\"foo\").Locator(\"span\")",
             "java" => "frameLocator().getByText(\"foo\").locator(\"span\")",
             "javascript" => "frameLocator().getByText('foo').locator('span')",
             "python" => "frame_locator().get_by_text(\"foo\").locator(\"span\")"
           }

    assert as_locator("javascript", "internal:control=any-frame") == "frameLocator()"
    assert as_locator("python", "internal:control=any-frame") == "frame_locator()"
    assert as_locator("java", "internal:control=any-frame") == "frameLocator()"
    assert as_locator("csharp", "internal:control=any-frame") == "FrameLocator()"
  end

  test "generate multiple locators", %{page: page} do
    selector =
      page
      |> Page.locator("div", has_text: "foo")
      |> Locator.nth(0)
      |> Locator.filter(has: page |> Page.locator("span", has_not_text: "bar") |> Locator.nth(-1))
      |> Map.fetch!(:_selector)

    locators = %{
      "javascript" => [
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div').filter({ hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).first().filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span').filter({ hasNotText: 'bar' }).nth(-1) })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).last() })",
        "locator('div', { hasText: 'foo' }).nth(0).filter({ has: locator('span', { hasNotText: 'bar' }).nth(-1) })"
      ],
      "java" => [
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).nth(-1)))",
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).nth(-1)))",
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).nth(-1)))",
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).nth(-1)))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).nth(-1)))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).first().filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).nth(-1)))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\").filter(new Locator.FilterOptions().setHasNotText(\"bar\")).nth(-1)))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).last()))",
        "locator(\"div\", new Page.LocatorOptions().setHasText(\"foo\")).nth(0).filter(new Locator.FilterOptions().setHas(locator(\"span\", new Page.LocatorOptions().setHasNotText(\"bar\")).nth(-1)))"
      ],
      "python" => [
        "locator(\"div\").filter(has_text=\"foo\").first.filter(has=locator(\"span\").filter(has_not_text=\"bar\").last)",
        "locator(\"div\").filter(has_text=\"foo\").first.filter(has=locator(\"span\").filter(has_not_text=\"bar\").nth(-1))",
        "locator(\"div\").filter(has_text=\"foo\").first.filter(has=locator(\"span\", has_not_text=\"bar\").last)",
        "locator(\"div\").filter(has_text=\"foo\").first.filter(has=locator(\"span\", has_not_text=\"bar\").nth(-1))",
        "locator(\"div\").filter(has_text=\"foo\").nth(0).filter(has=locator(\"span\").filter(has_not_text=\"bar\").last)",
        "locator(\"div\").filter(has_text=\"foo\").nth(0).filter(has=locator(\"span\").filter(has_not_text=\"bar\").nth(-1))",
        "locator(\"div\").filter(has_text=\"foo\").nth(0).filter(has=locator(\"span\", has_not_text=\"bar\").last)",
        "locator(\"div\").filter(has_text=\"foo\").nth(0).filter(has=locator(\"span\", has_not_text=\"bar\").nth(-1))",
        "locator(\"div\", has_text=\"foo\").first.filter(has=locator(\"span\").filter(has_not_text=\"bar\").last)",
        "locator(\"div\", has_text=\"foo\").first.filter(has=locator(\"span\").filter(has_not_text=\"bar\").nth(-1))",
        "locator(\"div\", has_text=\"foo\").first.filter(has=locator(\"span\", has_not_text=\"bar\").last)",
        "locator(\"div\", has_text=\"foo\").first.filter(has=locator(\"span\", has_not_text=\"bar\").nth(-1))",
        "locator(\"div\", has_text=\"foo\").nth(0).filter(has=locator(\"span\").filter(has_not_text=\"bar\").last)",
        "locator(\"div\", has_text=\"foo\").nth(0).filter(has=locator(\"span\").filter(has_not_text=\"bar\").nth(-1))",
        "locator(\"div\", has_text=\"foo\").nth(0).filter(has=locator(\"span\", has_not_text=\"bar\").last)",
        "locator(\"div\", has_text=\"foo\").nth(0).filter(has=locator(\"span\", has_not_text=\"bar\").nth(-1))"
      ],
      "csharp" => [
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Nth(-1) })",
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Nth(-1) })",
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Nth(-1) })",
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\").Filter(new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Nth(-1) })",
        "Locator(\"div\", new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\", new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Nth(-1) })",
        "Locator(\"div\", new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\", new() { HasText = \"foo\" }).First.Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Nth(-1) })",
        "Locator(\"div\", new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\", new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\").Filter(new() { HasNotText = \"bar\" }).Nth(-1) })",
        "Locator(\"div\", new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Last })",
        "Locator(\"div\", new() { HasText = \"foo\" }).Nth(0).Filter(new() { Has = Locator(\"span\", new() { HasNotText = \"bar\" }).Nth(-1) })"
      ]
    }

    for lang <- ~w(javascript java python csharp), do: assert(as_locators(lang, selector) == locators[lang])
  end

  # it.describe(() => { it.beforeEach(...) }): the beforeEach runs at the top of its one test.
  test "reverse engineer internal:has-text locators", %{context: context, page: page} do
    Api.call(nil, context, fn -> BrowserContext._show_recorder(context, %{language: "javascript"}) end)

    Page.set_content!(page, """
      <div>Hello <span>world</span></div>
      <div>Goodbye <span mark=1>world</span></div>
    """)

    assert generate_for_node(page, "[mark=\"1\"]") == %{
             "csharp" => "Locator(\"div\").Filter(new() { HasText = \"Goodbye world\" }).Locator(\"span\")",
             "java" =>
               "locator(\"div\").filter(new Locator.FilterOptions().setHasText(\"Goodbye world\")).locator(\"span\")",
             "javascript" => "locator('div').filter({ hasText: 'Goodbye world' }).locator('span')",
             "python" => "locator(\"div\").filter(has_text=\"Goodbye world\").locator(\"span\")"
           }

    assert as_locator("javascript", "div >> internal:has-text=\"foo\"s") ==
             "locator('div').locator('internal:has-text=\"foo\"s')"

    assert as_locator("javascript", "div >> internal:has-not-text=\"foo\"s") ==
             "locator('div').locator('internal:has-not-text=\"foo\"s')"
  end

  test "asLocator internal:and" do
    assert as_locator("javascript", "div >> internal:and=\"span >> article\"") ==
             "locator('div').and(locator('span').locator('article'))"

    assert as_locator("python", "div >> internal:and=\"span >> article\"") ==
             "locator(\"div\").and_(locator(\"span\").locator(\"article\"))"

    assert as_locator("java", "div >> internal:and=\"span >> article\"") ==
             "locator(\"div\").and(locator(\"span\").locator(\"article\"))"

    assert as_locator("csharp", "div >> internal:and=\"span >> article\"") ==
             "Locator(\"div\").And(Locator(\"span\").Locator(\"article\"))"
  end

  test "asLocator internal:or" do
    assert as_locator("javascript", "div >> internal:or=\"span >> article\"") ==
             "locator('div').or(locator('span').locator('article'))"

    assert as_locator("python", "div >> internal:or=\"span >> article\"") ==
             "locator(\"div\").or_(locator(\"span\").locator(\"article\"))"

    assert as_locator("java", "div >> internal:or=\"span >> article\"") ==
             "locator(\"div\").or(locator(\"span\").locator(\"article\"))"

    assert as_locator("csharp", "div >> internal:or=\"span >> article\"") ==
             "Locator(\"div\").Or(Locator(\"span\").Locator(\"article\"))"
  end

  test "asLocator internal:chain" do
    assert as_locator("javascript", "div >> internal:chain=\"span >> article\"") ==
             "locator('div').locator(locator('span').locator('article'))"

    assert as_locator("python", "div >> internal:chain=\"span >> article\"") ==
             "locator(\"div\").locator(locator(\"span\").locator(\"article\"))"

    assert as_locator("java", "div >> internal:chain=\"span >> article\"") ==
             "locator(\"div\").locator(locator(\"span\").locator(\"article\"))"

    assert as_locator("csharp", "div >> internal:chain=\"span >> article\"") ==
             "Locator(\"div\").Locator(Locator(\"span\").Locator(\"article\"))"
  end

  test "reverse engineer nested locators", %{page: page} do
    assert generate(
             page
             |> Page.get_by_role(:row)
             |> Locator.locator(page |> Page.get_by_role(:cell) |> Locator.nth(2))
           ) ==
             %{
               "csharp" => "GetByRole(AriaRole.Row).Locator(GetByRole(AriaRole.Cell).Nth(2))",
               "java" => "getByRole(AriaRole.ROW).locator(getByRole(AriaRole.CELL).nth(2))",
               "javascript" => "getByRole('row').locator(getByRole('cell').nth(2))",
               "python" => "get_by_role(\"row\").locator(get_by_role(\"cell\").nth(2))"
             }

    locator =
      page
      |> Page.locator("div")
      |> Locator.and_(Page.get_by_text(page, "foo"))
      |> Locator.or_(page |> Page.locator("span") |> Locator.locator(Page.locator(page, "a")))
      |> Locator.first()

    assert generate(locator) == %{
             "csharp" => "Locator(\"div\").And(GetByText(\"foo\")).Or(Locator(\"span\").Locator(Locator(\"a\"))).First",
             "java" => "locator(\"div\").and(getByText(\"foo\")).or(locator(\"span\").locator(locator(\"a\"))).first()",
             "javascript" => "locator('div').and(getByText('foo')).or(locator('span').locator(locator('a'))).first()",
             "python" =>
               "locator(\"div\").and_(get_by_text(\"foo\")).or_(locator(\"span\").locator(locator(\"a\"))).first"
           }
  end

  test "asLocator xpath" do
    selector = "//*[contains(normalizer-text(), 'foo']"
    assert as_locator("javascript", selector) == "locator('//*[contains(normalizer-text(), \\'foo\\']')"
    assert as_locator("python", selector) == "locator(\"//*[contains(normalizer-text(), 'foo']\")"
    assert as_locator("java", selector) == "locator(\"//*[contains(normalizer-text(), 'foo']\")"
    assert as_locator("csharp", selector) == "Locator(\"//*[contains(normalizer-text(), 'foo']\")"
  end

  test "reverse engineer regex flags" do
    assert generate_for_selector("internal:text=/a.b/ims") == %{
             "csharp" =>
               "GetByText(new Regex(\"a.b\", RegexOptions.IgnoreCase | RegexOptions.Multiline | RegexOptions.Singleline))",
             "java" =>
               "getByText(Pattern.compile(\"a.b\", Pattern.CASE_INSENSITIVE | Pattern.MULTILINE | Pattern.DOTALL))",
             "javascript" => "getByText(/a.b/ims)",
             "python" => "get_by_text(re.compile(r\"a.b\", re.IGNORECASE | re.MULTILINE | re.DOTALL))"
           }

    assert generate_for_selector("internal:role=button[name=/a.b/s]") == %{
             "csharp" =>
               "GetByRole(AriaRole.Button, new() { NameRegex = new Regex(\"a.b\", RegexOptions.Singleline) })",
             "java" =>
               "getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName(Pattern.compile(\"a.b\", Pattern.DOTALL)))",
             "javascript" => "getByRole('button', { name: /a.b/s })",
             "python" => "get_by_role(\"button\", name=re.compile(r\"a.b\", re.DOTALL))"
           }
  end

  test "should not oom in locator parser", %{page: page} do
    l = &Page.locator(page, &1)

    frame = fn text ->
      l.("#f0")
      |> Locator.content_frame()
      |> FrameLocator.locator("#f0_mid_0")
      |> Locator.content_frame()
      |> FrameLocator.locator(text)
    end

    group = fn [a, b, c, d, e, f, g] ->
      Locator.or_(
        l.(a),
        l.(b)
        |> Locator.or_(l.(c))
        |> Locator.or_(Locator.or_(frame.(d), l.(e)))
        |> Locator.or_(Locator.or_(frame.(f), l.(g)))
      )
    end

    texts = for i <- 2..29, do: "text=L#{i}"

    locator =
      texts
      |> Enum.chunk_every(7)
      |> Enum.reduce(l.("text=L1"), fn texts, locator -> Locator.or_(locator, group.(texts)) end)

    {:error, error} = Locator.count(locator)
    assert error.message =~ "Frame locators are not allowed inside composite locators"
  end

  test "asLocatorDescription invalid input" do
    assert as_locator_description("javascript", "body >> internal:describe=\"desc\"") == "desc"
    assert as_locator_description("javascript", "body >> internal:describe=12") == "locator('body')"
    # Deviation: parseCSS is not ported, so invalid CSS is rendered instead of returned as is.
    assert as_locator_description("javascript", "following-sibling::*[1]") == "locator('following-sibling::*[1]')"

    assert as_locator_description("javascript", "body >> internal:describe=\"desc\" >> div") ==
             "locator('body').locator('div')"
  end

  test "resolveSelector returns locatorCode for sdkLanguage", %{page: page} do
    Page.set_content!(page, "<button id=\"submit\">Submit</button>")
    assert Page.aria_snapshot!(page, mode: :ai) =~ "button \"Submit\" [ref=e2]"
    frame = Page.main_frame(page)
    selector = "aria-ref=e2"

    no_language = channel_call(frame, :resolveSelector, %{selector: selector})
    assert no_language.resolvedSelector == "internal:role=button[name=\"Submit\"i]"
    assert no_language[:locatorCode] == nil

    assert channel_call(frame, :resolveSelector, %{selector: selector, sdkLanguage: "javascript"}).locatorCode ==
             "getByRole('button', { name: 'Submit' })"

    assert channel_call(frame, :resolveSelector, %{selector: selector, sdkLanguage: "python"}).locatorCode ==
             "get_by_role(\"button\", name=\"Submit\")"

    assert channel_call(frame, :resolveSelector, %{selector: selector, sdkLanguage: "java"}).locatorCode ==
             "getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName(\"Submit\"))"

    assert channel_call(frame, :resolveSelector, %{selector: selector, sdkLanguage: "csharp"}).locatorCode ==
             "GetByRole(AriaRole.Button, new() { Name = \"Submit\" })"
  end

  test "asLocatorDescription via LocalUtils", %{page: page} do
    channel = Connection.local_utils(Heap.get(page, :_connection))
    selector = "internal:role=button[name=\"Submit\"i]"

    assert channel_call(channel, :asLocatorDescription, %{selector: selector, sdkLanguage: "javascript"}).description ==
             "getByRole('button', { name: 'Submit' })"

    assert channel_call(channel, :asLocatorDescription, %{selector: selector, sdkLanguage: "python"}).description ==
             "get_by_role(\"button\", name=\"Submit\")"

    assert channel_call(channel, :asLocatorDescription, %{selector: selector, sdkLanguage: "java"}).description ==
             "getByRole(AriaRole.BUTTON, new Page.GetByRoleOptions().setName(\"Submit\"))"

    assert channel_call(channel, :asLocatorDescription, %{selector: selector, sdkLanguage: "csharp"}).description ==
             "GetByRole(AriaRole.Button, new() { Name = \"Submit\" })"

    described =
      channel_call(channel, :asLocatorDescription, %{
        selector: "#submit >> internal:describe=\"Submit button\"",
        sdkLanguage: "python"
      })

    assert described.description == "Submit button"
  end
end
