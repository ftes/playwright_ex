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

  # Elixir only: a `Regex` stands in for a `RegExp` that the browser or driver runs. Raises on
  # options and PCRE-only syntax JS cannot run; other differences (`$` before a final newline,
  # `\w`/`\b` being Unicode-aware under `u`) are not detected.
  @js_options [:caseless, :multiline, :dotall, {:newline, :anycrlf}, :unicode, :ucp, :export]
  @pcre_only_escapes ~c"AzZGQEKRhHXCNeog"

  @doc false
  def check_js_compatible!(%Regex{} = regex) do
    case Regex.opts(regex) -- @js_options do
      [] -> :ok
      opts -> raise ArgumentError, "Regex options #{inspect(opts)} have no JS RegExp equivalent: #{inspect(regex)}"
    end

    case pcre_only(Regex.source(regex), :unicode in Regex.opts(regex), false) do
      nil -> regex
      what -> raise ArgumentError, "#{what} is not JS RegExp syntax: #{inspect(regex)}"
    end
  end

  defp pcre_only(<<?\\, c, _::binary>>, _unicode, _in_class) when c in @pcre_only_escapes, do: "\\#{<<c>>}"
  defp pcre_only(<<"\\x{", _::binary>>, _unicode, _in_class), do: "\\x{...}"
  defp pcre_only(<<?\\, c, _::binary>>, false, _in_class) when c in ~c"pP", do: "\\#{<<c>>} without the u modifier"

  defp pcre_only(<<?\\, c, ?{, rest::binary>>, unicode, in_class) when c in ~c"pP",
    do: pcre_only(rest |> String.split("}", parts: 2) |> List.last(), unicode, in_class)

  defp pcre_only(<<?\\, _::utf8, rest::binary>>, unicode, in_class), do: pcre_only(rest, unicode, in_class)
  defp pcre_only(<<?], rest::binary>>, unicode, true), do: pcre_only(rest, unicode, false)

  defp pcre_only(<<"[:", rest::binary>>, unicode, true) do
    if Regex.match?(~r/^\^?[a-z]+:\]/, rest), do: "a POSIX class [:...:]", else: pcre_only(rest, unicode, true)
  end

  defp pcre_only(<<_::utf8, rest::binary>>, unicode, true), do: pcre_only(rest, unicode, true)
  defp pcre_only(<<?[, rest::binary>>, unicode, false), do: pcre_only(rest, unicode, true)

  defp pcre_only(<<"(?", rest::binary>>, unicode, false) do
    cond do
      String.starts_with?(rest, [">", "|", "#", "P", "R", "&", "(", "+", "'"]) -> "(?#{String.first(rest)}"
      Regex.match?(~r/^[0-9]/, rest) -> "(?#{String.first(rest)}"
      Regex.match?(~r/^[\^a-zA-Z-]*\)/, rest) -> "an inline option group (?...)"
      true -> pcre_only(rest, unicode, false)
    end
  end

  defp pcre_only(<<"(*", c, _::binary>>, _unicode, false) when c in ?A..?Z, do: "a backtracking verb (*...)"
  defp pcre_only(<<c, ?+, _::binary>>, _unicode, false) when c in ~c"*+?", do: "a possessive quantifier #{<<c, ?+>>}"

  defp pcre_only(<<?{, rest::binary>>, unicode, false) do
    if Regex.match?(~r/^\d+(,\d*)?\}\+/, rest), do: "a possessive quantifier }+", else: pcre_only(rest, unicode, false)
  end

  defp pcre_only(<<_::utf8, rest::binary>>, unicode, false), do: pcre_only(rest, unicode, false)
  defp pcre_only(<<_, rest::binary>>, unicode, in_class), do: pcre_only(rest, unicode, in_class)
  defp pcre_only(<<>>, _unicode, _in_class), do: nil

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
