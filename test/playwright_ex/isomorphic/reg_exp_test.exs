defmodule PlaywrightEx.Isomorphic.RegExpTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Isomorphic.RegExp
  alias PlaywrightEx.Protocol.Serializers

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

    assert Serializers.regex_flags(~r/a/imsu) == "imsu"
  end

  test "options JS cannot run raise" do
    for re <- [~r/a b/x, ~r/a+/U, Regex.compile!("a$", [:dollar_endonly])] do
      assert_raise ArgumentError, ~r/no JS RegExp equivalent/, fn -> Serializers.regex_flags(re) end
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
        Serializers.regex_flags(re)
      end
    end
  end
end
