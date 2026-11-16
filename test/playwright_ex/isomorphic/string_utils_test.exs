defmodule PlaywrightEx.Isomorphic.StringUtilsTest do
  # Not mirrored from upstream: `normalizeWhiteSpace` has no unit spec there.
  use ExUnit.Case, async: true

  import PlaywrightEx.Isomorphic.StringUtils, only: [normalize_white_space: 1]

  test "normalize_white_space/1 strips zero-width spaces and soft hyphens" do
    assert normalize_white_space("a\u{200b}b\u{00ad}c") == "abc"
  end

  test "normalize_white_space/1 trims and collapses whitespace runs to one space" do
    assert normalize_white_space("  \t a \n\r\n  b\f\vc  ") == "a b c"
  end

  test "normalize_white_space/1 strips before it trims" do
    assert normalize_white_space(" \u{200b} a  b \u{00ad} ") == "a b"
  end

  test "normalize_white_space/1 uses the whitespace of JS `\\s`" do
    js_white_space = "\u{00a0}\u{1680}\u{2000}\u{200a}\u{2028}\u{2029}\u{202f}\u{205f}\u{3000}\u{feff}"
    assert normalize_white_space("#{js_white_space}a#{js_white_space}b#{js_white_space}") == "a b"
    # U+0085 (NEL) is whitespace to PCRE and Unicode, not to JS.
    assert normalize_white_space("\u0085a\u0085 b") == "\u0085a\u0085 b"
  end
end
