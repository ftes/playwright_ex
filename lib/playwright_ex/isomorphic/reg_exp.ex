defmodule PlaywrightEx.Isomorphic.RegExp do
  @moduledoc """
  Elixir only: the JS `RegExp` values the selector and locator parsers build (`new RegExp(source,
  flags)`), as `source` and `flags` normalized like JS. They are rendered, never matched, so JS
  syntax that PCRE lacks (`[^]`, the `d`/`g`/`v`/`y` flags) survives. Not a `Regex`: the source
  is not validated beyond the flags.
  """

  defstruct source: "(?:)", flags: ""

  @flag_order ~c"dgimsuvy"

  # new RegExp(source, flags): raises on unknown or repeated flags, and on `u` with `v`.
  def new(source, flags \\ "") do
    chars = String.to_charlist(flags)

    if Enum.any?(chars, &(&1 not in @flag_order)) or Enum.uniq(chars) != chars or
         (?u in chars and ?v in chars),
       do: raise(ArgumentError, "Invalid flags supplied to RegExp constructor '#{flags}'")

    %__MODULE__{
      source: escape_pattern(source),
      flags: for(flag <- @flag_order, flag in chars, into: "", do: <<flag>>)
    }
  end

  # String(re)
  def to_string(%__MODULE__{source: source, flags: flags}), do: "/#{source}/#{flags}"

  # EscapeRegExpPattern: `re.source` escapes `/` outside classes and line terminators, `(?:)` if empty.
  defp escape_pattern(""), do: "(?:)"
  defp escape_pattern(source), do: escape_pattern(source, false, "")

  defp escape_pattern(<<?\\, c::utf8, rest::binary>>, in_class, acc) when c not in [?\n, ?\r, 0x2028, 0x2029],
    do: escape_pattern(rest, in_class, <<acc::binary, ?\\, c::utf8>>)

  defp escape_pattern(<<?/, rest::binary>>, false, acc), do: escape_pattern(rest, false, acc <> "\\/")
  defp escape_pattern(<<?[, rest::binary>>, false, acc), do: escape_pattern(rest, true, acc <> "[")
  defp escape_pattern(<<?], rest::binary>>, true, acc), do: escape_pattern(rest, false, acc <> "]")
  defp escape_pattern(<<?\n, rest::binary>>, in_class, acc), do: escape_pattern(rest, in_class, acc <> "\\n")
  defp escape_pattern(<<?\r, rest::binary>>, in_class, acc), do: escape_pattern(rest, in_class, acc <> "\\r")

  defp escape_pattern(<<0x2028::utf8, rest::binary>>, in_class, acc),
    do: escape_pattern(rest, in_class, acc <> "\\u2028")

  defp escape_pattern(<<0x2029::utf8, rest::binary>>, in_class, acc),
    do: escape_pattern(rest, in_class, acc <> "\\u2029")

  defp escape_pattern(<<c::utf8, rest::binary>>, in_class, acc),
    do: escape_pattern(rest, in_class, <<acc::binary, c::utf8>>)

  defp escape_pattern(<<c, rest::binary>>, in_class, acc), do: escape_pattern(rest, in_class, <<acc::binary, c>>)
  defp escape_pattern(<<>>, _in_class, acc), do: acc

  # JSON.stringify(re) is "{}".
  defimpl JSON.Encoder do
    def encode(_re, _encoder), do: "{}"
  end
end
