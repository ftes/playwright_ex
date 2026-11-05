defmodule PlaywrightEx.Isomorphic.LocatorGeneratorsTest do
  # Elixir only: the "elixir" factory, for the locators of tests/library/locator-generator.spec.ts.
  # Each rendering is also evaluated with `page` bound: it must build the same selector.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Isomorphic.LocatorGenerators
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  defp elixir(locator), do: LocatorGenerators.as_locator("elixir", selector(locator))

  defp selector(locator), do: Map.get(locator, :_selector) || Map.get(locator, :_frameSelector)

  defp assert_elixir(page, locator, expected) do
    assert elixir(locator) == expected
    aliases = "alias PlaywrightEx.{FrameLocator, Locator, Page}\n"
    {evaluated, _} = Code.eval_string(aliases <> expected, page: page)
    assert selector(evaluated) == selector(locator)
  end

  test "reverse engineer locators", %{page: page} do
    assert_elixir(page, Page.get_by_test_id(page, "Hello"), ~S'Page.get_by_test_id(page, "Hello")')
    assert_elixir(page, Page.get_by_test_id(page, ~S'He"llo'), ~S'Page.get_by_test_id(page, "He\"llo")')
    assert_elixir(page, Page.get_by_test_id(page, ~r/He"llo/), ~S'Page.get_by_test_id(page, ~r/He"llo/)')
    assert_elixir(page, Page.get_by_test_id(page, ~r/He\\"llo/), ~S'Page.get_by_test_id(page, ~r/He\\"llo/)')
    assert_elixir(page, Page.get_by_text(page, "Hello", exact: true), ~S'Page.get_by_text(page, "Hello", exact: true)')
    assert_elixir(page, Page.get_by_text(page, ~r/Hello/), ~S'Page.get_by_text(page, ~r/Hello/)')
    assert_elixir(page, Page.get_by_label(page, ~r/Last\s+name/i), ~S'Page.get_by_label(page, ~r/Last\s+name/i)')
    assert_elixir(page, Page.get_by_placeholder(page, "hello"), ~S'Page.get_by_placeholder(page, "hello")')

    assert_elixir(
      page,
      Page.get_by_alt_text(page, "Hello", exact: true),
      ~S'Page.get_by_alt_text(page, "Hello", exact: true)'
    )

    assert_elixir(page, Page.get_by_title(page, ~r/wor/i), ~S'Page.get_by_title(page, ~r/wor/i)')
    assert_elixir(page, Page.get_by_title(page, "hello my\nwo\"rld"), ~S'Page.get_by_title(page, "hello my\nwo\"rld")')
    assert_elixir(page, Page.get_by_text(page, "\#{x}"), ~S'Page.get_by_text(page, "\#{x}")')

    # JS-only flags are dropped, `v` is Elixir's `u`.
    for {flags, elixir_flags} <- [{"u", "u"}, {"s", "s"}, {"y", ""}, {"d", ""}, {"v", "u"}, {"gm", "m"}] do
      assert LocatorGenerators.as_locator("elixir", "internal:text=/Hello/#{flags}") ==
               "Page.get_by_text(page, ~r/Hello/#{elixir_flags})"
    end
  end

  test "reverse engineer getByRole", %{page: page} do
    assert_elixir(page, Page.get_by_role(page, :button), ~S'Page.get_by_role(page, :button)')

    assert_elixir(
      page,
      Page.get_by_role(page, :button, name: "Hello"),
      ~S'Page.get_by_role(page, :button, name: "Hello")'
    )

    assert_elixir(
      page,
      Page.get_by_role(page, :button, name: ~r/Hello/),
      ~S'Page.get_by_role(page, :button, name: ~r/Hello/)'
    )

    assert_elixir(
      page,
      Page.get_by_role(page, :button, name: ~S'He"llo', exact: true),
      ~S'Page.get_by_role(page, :button, name: "He\"llo", exact: true)'
    )

    assert_elixir(
      page,
      Page.get_by_role(page, :button, checked: true, pressed: false, level: 3, include_hidden: true),
      ~S'Page.get_by_role(page, :button, checked: true, include_hidden: true, level: 3, pressed: false)'
    )

    assert_elixir(
      page,
      Page.get_by_role(page, :alert, name: "Upload", description: ~r/doc\.pdf/),
      ~S'Page.get_by_role(page, :alert, name: "Upload", description: ~r/doc\.pdf/)'
    )

    assert LocatorGenerators.as_locator("elixir", ~S'internal:role=fancy-role[disabled]') ==
             ~S'Page.get_by_role(page, :"fancy-role", disabled: nil)'
  end

  test "reverse engineer chains", %{page: page} do
    assert_elixir(
      page,
      page |> Page.locator("div") |> Locator.nth(3) |> Locator.first() |> Locator.last(),
      ~S'Page.locator(page, "div") |> Locator.nth(3) |> Locator.first() |> Locator.last()'
    )

    assert_elixir(
      page,
      page |> Page.get_by_text("Hello") |> Locator.filter(has_text: ~r/wo\/\srld\n/),
      ~S'Page.get_by_text(page, "Hello") |> Locator.filter(has_text: ~r/wo\/\srld\n/)'
    )

    assert_elixir(
      page,
      page |> Page.get_by_text("Hello") |> Locator.filter(has_not_text: "wo\"rld\n"),
      ~S'Page.get_by_text(page, "Hello") |> Locator.filter(has_not_text: "wo\"rld\n")'
    )

    assert_elixir(
      page,
      page |> Page.get_by_text("Hello") |> Locator.visible() |> Locator.locator("div"),
      ~S'Page.get_by_text(page, "Hello") |> Locator.visible() |> Locator.locator("div")'
    )

    assert_elixir(
      page,
      page |> Page.get_by_text("Hello") |> Locator.filter(visible: false),
      ~S'Page.get_by_text(page, "Hello") |> Locator.filter(visible: false)'
    )

    assert_elixir(
      page,
      page
      |> Page.locator("section")
      |> Locator.filter(has: page |> Page.locator("div") |> Locator.filter(has_not: Page.locator(page, "span")))
      |> Locator.filter(has_text: "foo"),
      ~S'Page.locator(page, "section") |> Locator.filter(has: Page.locator(page, "div") |> Locator.filter(has_not: Page.locator(page, "span"))) |> Locator.filter(has_text: "foo")'
    )

    assert_elixir(
      page,
      page
      |> Page.locator("div")
      |> Locator.and_(Page.get_by_text(page, "foo"))
      |> Locator.or_(page |> Page.locator("span") |> Locator.locator(Page.locator(page, "a")))
      |> Locator.first(),
      ~S'Page.locator(page, "div") |> Locator.and_(Page.get_by_text(page, "foo")) |> Locator.or_(Page.locator(page, "span") |> Locator.locator(Page.locator(page, "a"))) |> Locator.first()'
    )
  end

  test "reverse engineer frameLocator", %{page: page} do
    assert_elixir(
      page,
      page
      |> Page.frame_locator("iframe")
      |> FrameLocator.get_by_text("foo", exact: true)
      |> Locator.frame_locator("frame")
      |> FrameLocator.first()
      |> FrameLocator.locator("span"),
      ~S'Page.locator(page, "iframe") |> Locator.content_frame() |> FrameLocator.get_by_text("foo", exact: true) |> Locator.locator("frame") |> Locator.first() |> Locator.content_frame() |> FrameLocator.locator("span")'
    )

    assert_elixir(
      page,
      page |> Page.frame_locator() |> FrameLocator.get_by_text("foo") |> Locator.locator("span"),
      ~S'Page.frame_locator(page) |> FrameLocator.get_by_text("foo") |> Locator.locator("span")'
    )
  end

  test "generate multiple locators", %{page: page} do
    selector =
      page
      |> Page.locator("div", has_text: "foo")
      |> Locator.nth(0)
      |> Locator.filter(has: page |> Page.locator("span", has_not_text: "bar") |> Locator.nth(-1))
      |> selector()

    assert LocatorGenerators.as_locators("elixir", selector, false, 4) == [
             ~S'Page.locator(page, "div") |> Locator.filter(has_text: "foo") |> Locator.first() |> Locator.filter(has: Page.locator(page, "span") |> Locator.filter(has_not_text: "bar") |> Locator.last())',
             ~S'Page.locator(page, "div") |> Locator.filter(has_text: "foo") |> Locator.first() |> Locator.filter(has: Page.locator(page, "span") |> Locator.filter(has_not_text: "bar") |> Locator.nth(-1))',
             ~S'Page.locator(page, "div") |> Locator.filter(has_text: "foo") |> Locator.first() |> Locator.filter(has: Page.locator(page, "span", has_not_text: "bar") |> Locator.last())',
             ~S'Page.locator(page, "div") |> Locator.filter(has_text: "foo") |> Locator.first() |> Locator.filter(has: Page.locator(page, "span", has_not_text: "bar") |> Locator.nth(-1))'
           ]
  end

  test "Locator to_string, String.Chars and Inspect render Elixir", %{page: page} do
    locator = page |> Page.get_by_role(:button, name: "Submit") |> Locator.first()
    assert Locator.to_string(locator) == ~S'Page.get_by_role(page, :button, name: "Submit") |> Locator.first()'
    assert to_string(locator) == Locator.to_string(locator)

    assert inspect(locator) ==
             ~S'#PlaywrightEx.Locator<Page.get_by_role(page, :button, name: "Submit") |> Locator.first()>'

    assert inspect(Locator.describe(locator, "Submit button")) == "#PlaywrightEx.Locator<Submit button>"
  end
end
