defmodule PlaywrightEx.RegExpTest do
  # Not mirrored from upstream: `PlaywrightEx.RegExp` and the `Regex` <-> JS `RegExp` mapping.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Protocol.Serializers
  alias PlaywrightEx.RegExp
  alias PlaywrightEx.Route

  doctest RegExp

  test "new/2 validates the flags as JS, orders them and escapes the source" do
    assert %RegExp{source: "a\\/b", flags: "dgimsvy"} = RegExp.new("a/b", "yvsmigd")
    assert RegExp.new("") == %RegExp{source: "(?:)", flags: ""}
    assert RegExp.new("[/]\\/") |> RegExp.source() == "[/]\\/"
    assert RegExp.new("a", "iu") |> RegExp.flags() == "iu"
    assert RegExp.to_string(RegExp.new("a/b", "g")) == "/a\\/b/g"
    assert "#{RegExp.new("x", "v")}" == "/x/v"

    for flags <- ["x", "gg", "uv", "I"] do
      assert_raise ArgumentError, "Invalid flags supplied to RegExp constructor '#{flags}'", fn ->
        RegExp.new("a", flags)
      end
    end
  end

  test "Regex and RegExp serialize to the same JS regex" do
    assert Serializers.serialize_plain_value(RegExp.new("[^]", "gv")) == %{r: %{p: "[^]", f: "gv"}}
    assert Serializers.serialize_plain_value(~r/a.b/is) == %{r: %{p: "a.b", f: "is"}}
    assert RegExp.to_js(~r/a/m) == {"a", "m"}
    assert RegExp.to_js("a") == {nil, nil}
  end

  test "a JS regex always parses to a RegExp, losslessly" do
    for {p, f} <- [
          {"a\\/b.c", "imsu"},
          {"a", "g"},
          {"a", "y"},
          {"a", "v"},
          {"a[^]b", ""},
          {"[]", ""},
          {"\\u00e9", ""},
          {"\\A", ""},
          {"(?<=a+)b", ""}
        ] do
      assert Serializers.parse_serialized_value(%{r: %{p: p, f: f}}, nil) == %RegExp{source: p, flags: f}
    end
  end

  test "a RegExp compiles to a Regex for matching in Elixir" do
    for {re, yes, no} <- [
          {RegExp.new("a[^]b"), "a\nb", "ab"},
          {RegExp.new("x[]"), nil, "x"},
          {RegExp.new("^\\u00e9\\u{1F600}$", "u"), "é😀", "e"},
          {RegExp.new("^\\uD83D\\uDE00$"), "😀", "x"},
          {RegExp.new("^\\A\\z$"), "Az", "\\A"},
          {RegExp.new("^[[a]$"), "[", "b"},
          {RegExp.new("^a$"), "a", "a\n"},
          {RegExp.new("^.$"), "x", "\r"},
          {RegExp.new("^\\v$"), "\v", "v"},
          {RegExp.new("A", "i"), "xa", "b"},
          {RegExp.new("^b", "m"), "a\nb", "ab"},
          {RegExp.new("a", "y"), "ab", "ba"},
          {RegExp.new("a", "gd"), "ba", "b"}
        ] do
      if yes, do: assert(RegExp.test(re, yes), "#{re} should match #{inspect(yes)}")
      refute RegExp.test(re, no), "#{re} should not match #{inspect(no)}"
    end

    for {re, why} <- [
          {RegExp.new("[a&&b]", "v"), "the v flag"},
          {RegExp.new("(?<=a+)b"), "lookbehind"},
          {RegExp.new("a++"), "possessive quantifier"},
          {RegExp.new("\\u{110000}", "u"), "\\u{...}"},
          {RegExp.new("\\uD800", "u"), "lone surrogate"}
        ] do
      assert_raise ArgumentError, ~r/cannot be matched in Elixir \(.*#{Regex.escape(why)}/, fn ->
        RegExp.test(re, "")
      end
    end
  end

  test "a Regex JS can run passes, with its JS flags" do
    for re <- [
          ~r/a.b/ims,
          ~r/^\/path\?q=(?<id>\d+)$/,
          ~r/(?<=a)b(?!c)(?i:d)/,
          ~r/\p{L}+/u,
          ~r/[^]x[\]a-z]\cJ(?<n>a)\k<n>/,
          ~r/a{2,3}?b*?c+d?\+x}+/
        ] do
      assert RegExp.check_js_compatible!(re) == re
    end

    assert RegExp.regex_flags(~r/a/imsu) == "imsu"
  end

  test "new/2 takes a regex as JS's constructor does: its source, its flags unless given" do
    assert RegExp.new(~r"a/b"imsu) == %RegExp{source: "a\\/b", flags: "imsu"}
    assert RegExp.new(~r"a/b"i, "g") == %RegExp{source: "a\\/b", flags: "g"}
    assert RegExp.new(~r//) == %RegExp{source: "(?:)", flags: ""}

    re = RegExp.new("a[^]/b", "v")
    assert RegExp.new(re) == re
    assert RegExp.new(re, "i") == %RegExp{source: "a[^]\\/b", flags: "i"}

    # As the facade converts one, and Elixir then matches it as the browser does.
    assert RegExp.new(~r"^/users/\d+$") |> RegExp.compile!() |> Regex.match?("/users/12")
  end

  test "new/2 raises for a Regex JS cannot run, flags given or not" do
    for re <- [~r/a/x, ~r/\Aa\z/, ~r/(?>a)/, ~r/(?i)a/] do
      assert_raise ArgumentError, fn -> RegExp.new(re) end
      assert_raise ArgumentError, fn -> RegExp.new(re, "i") end
    end
  end

  test "options JS cannot run raise" do
    for re <- [~r/a b/x, ~r/a+/U, Regex.compile!("a$", [:dollar_endonly])] do
      assert_raise ArgumentError, ~r/no JS RegExp equivalent/, fn -> RegExp.regex_flags(re) end
    end
  end

  test "PCRE-only syntax raises" do
    for {re, what} <- [
          {~r/\Aa\z/, "\\A"},
          {~r/a\Z/, "\\Z"},
          {~r/\h/, "\\h"},
          {~r/[\h]/, "\\h"},
          {~r/\x{41}/, "\\x{...}"},
          {~r/\p{L}/, "\\p without the u modifier"},
          {~r/[[:alpha:]]/, "POSIX class"},
          {~r/(?>a)/, "(?>"},
          {~r/(?|a)/, "(?|"},
          {~r/(?#note)a/, "(?#"},
          {~r/(?P<n>a)/, "(?P"},
          {~r/(a)(?1)/, "(?1"},
          {~r/(?i)a/, "inline option group"},
          {~r/(*UTF)a/, "backtracking verb"},
          {~r/a++/, "possessive quantifier ++"},
          {~r/a{2}+/, "possessive quantifier }+"}
        ] do
      assert_raise ArgumentError, ~r/#{Regex.escape(what)}.* is not JS RegExp syntax/, fn ->
        RegExp.regex_flags(re)
      end
    end
  end

  @tag :page
  test "a JS-only RegExp works in locators and matchers", %{page: page} do
    Page.set_content!(page, "<div>Hello\nWorld</div><div>Hallo</div>")
    # `[^]` matches any character, `(?<=H[^]+)` a variable-length lookbehind.
    Expect.to_have_count!(Page.get_by_text(page, RegExp.new("Hello[^]World")), 1)
    Expect.to_have_text!(Page.locator(page, "div") |> Locator.first(), RegExp.new("(?<=H[^]+)World"))
    Expect.to_have_count!(Page.locator(page, "div", has_text: RegExp.new("[^]allo", "v")), 1)

    {:error, error} = Expect.to_have_text(Page.get_by_text(page, "Hallo"), RegExp.new("(?<=x+)y"), timeout: 100)
    assert error.message =~ "Expected pattern: /(?<=x+)y/"
    {:error, error} = Expect.not_to_have_text(Page.get_by_text(page, "Hallo"), RegExp.new("[^]", "v"), timeout: 100)
    assert error.message =~ "Expected pattern: not /[^]/v"
    assert Page.evaluate!(page, "() => /[^]/v") == RegExp.new("[^]", "v")
    assert Page.evaluate!(page, "re => re.flags + re.source", RegExp.new("a/b", "dgy")) == "dgya\\/b"
  end

  @tag :page
  test "url matchers take a RegExp", %{page: page, server: server} do
    Page.route!(page, RegExp.new("empty[^]html$", "d"), &Route.fulfill!(&1, body: "routed"))
    Page.goto!(page, server.empty_page)
    assert Page.content!(page) =~ "routed"
    Page.wait_for_url!(page, RegExp.new("/empty\\.html$"))
    Expect.to_have_url!(page, RegExp.new("[^]empty", "v"))

    assert_raise ArgumentError, ~r/cannot be matched in Elixir \(the v flag\)/, fn ->
      Page.wait_for_url!(page, RegExp.new("empty", "v"))
    end
  end
end
