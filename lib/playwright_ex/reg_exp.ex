defmodule PlaywrightEx.RegExp do
  @moduledoc """
  A JS `RegExp`, for patterns Elixir's `Regex` cannot express:

      Page.get_by_text(page, PlaywrightEx.RegExp.new("a[^]b", "v"))

  Wherever Playwright takes a `RegExp` (selectors and `get_by_*` options, `has_text`, `expect`
  matchers, URL matchers, `clear_cookies`, HAR `url:`, `evaluate` arguments), it takes either:

    * a `Regex` (`~r/.../`), sent as a JS regex with its modifiers `i`, `m`, `s`, `u`. Options
      and PCRE-only syntax JS cannot run (`x`, `U`, `\\A`, `\\z`, atomic groups, possessive
      quantifiers, inline `(?i)`, recursion, `\\K`) raise `ArgumentError`;
    * a `PlaywrightEx.RegExp` (`new/2`), sent as is: JS-only syntax such as `[^]`, the `v`, `y`,
      `d` and `g` flags, or variable-length lookbehind (`(?<=a+)`) works.

  Strings are always literal text (or globs, for URLs), never patterns.

  The source is not validated here: the browser or driver reports JS syntax errors. Matching in
  Elixir (`wait_for_url`, `Page.frame(url:)`, routes, `wait_for_request`) compiles a `RegExp` to
  a `Regex`: `[^]`, `\\uXXXX` and identity escapes are translated, the `y` flag anchors, `g` and
  `d` do not matter; a pattern PCRE cannot run (the `v` flag, unbounded lookbehind) raises
  `ArgumentError`. JS regexes returned by the driver (`evaluate`) are a `Regex` when it means the
  same (flags `imsu`, no translation), else a `PlaywrightEx.RegExp`.
  """

  import Kernel, except: [to_string: 1]

  defstruct source: "(?:)", flags: ""

  @typedoc "A JS regex: `source` as JS `re.source` (`/` escaped), `flags` in JS order."
  @type t :: %__MODULE__{source: String.t(), flags: String.t()}

  @flag_order ~c"dgimsuvy"

  @doc """
  `new RegExp(source, flags)`: raises `ArgumentError` on unknown or repeated flags (JS:
  `dgimsuvy`), and on `u` with `v`. `/` is escaped in the source, an empty one is `(?:)`.

      iex> PlaywrightEx.RegExp.new("a/b", "iv")
      %PlaywrightEx.RegExp{source: "a\\\\/b", flags: "iv"}
  """
  @spec new(String.t(), String.t()) :: t()
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

  @doc "`re.source`."
  @spec source(t()) :: String.t()
  def source(%__MODULE__{source: source}), do: source

  @doc "`re.flags`."
  @spec flags(t()) :: String.t()
  def flags(%__MODULE__{flags: flags}), do: flags

  @doc "`String(re)`: `/source/flags`."
  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{source: source, flags: flags}), do: "/#{source}/#{flags}"

  @doc false
  # isRegExp: a `Regex` or a `PlaywrightEx.RegExp`.
  def reg_exp?(value), do: is_struct(value, Regex) or is_struct(value, __MODULE__)

  @doc false
  # `{re.source, re.flags}` as sent to the browser or driver, `{nil, nil}` for anything else.
  def to_js(%__MODULE__{source: source, flags: flags}), do: {source, flags}
  def to_js(%Regex{} = regex), do: {Regex.source(regex), regex_flags(regex)}
  def to_js(_value), do: {nil, nil}

  @doc false
  # The `RegExp` a `Regex` stands for (`/` escaped as `re.source` does).
  def from_regex(%Regex{} = regex), do: new(Regex.source(regex), regex_flags(regex))
  def from_regex(%__MODULE__{} = re), do: re

  @doc false
  def regex_flags(regex) do
    opts = Regex.opts(check_js_compatible!(regex))
    for {opt, flag} <- [caseless: "i", multiline: "m", dotall: "s", unicode: "u"], opt in opts, into: "", do: flag
  end

  @doc false
  # `re.test(string)` in Elixir (`lastIndex` reset, as `urlMatches` does).
  def test(%Regex{} = regex, string), do: Regex.match?(regex, string)
  def test(%__MODULE__{} = re, string), do: Regex.match?(compile!(re), string)

  @doc false
  # `re.exec(string)` as `Regex.run(regex, string, return: :index)`, or nil when PCRE cannot run it.
  def exec_index(%Regex{} = regex, string), do: Regex.run(regex, string, return: :index)

  def exec_index(%__MODULE__{} = re, string) do
    case to_regex(re) do
      {:ok, regex} -> Regex.run(regex, string, return: :index)
      {:error, _reason} -> nil
    end
  end

  @doc false
  # The `Regex` that matches as `re` does in JS, for matching in Elixir; raises if PCRE cannot.
  def compile!(%__MODULE__{} = re) do
    case to_regex(re) do
      {:ok, regex} ->
        regex

      {:error, reason} ->
        raise ArgumentError,
              "#{to_string(re)} cannot be matched in Elixir (#{reason}); pass a Regex (~r//) or a JS-compatible pattern"
    end
  end

  @doc false
  def to_regex(%__MODULE__{source: source, flags: flags}) do
    with :ok <- if(String.contains?(flags, "v"), do: {:error, "the v flag"}, else: :ok),
         {:ok, pcre} <- js_to_pcre(source, String.contains?(flags, "u")),
         nil <- pcre_only(pcre, true, false),
         {:ok, regex} <- Regex.compile(pcre, pcre_options(flags)) do
      {:ok, regex}
    else
      {:error, {message, _offset}} -> {:error, Kernel.to_string(message)}
      {:error, reason} -> {:error, reason}
      what when is_binary(what) -> {:error, "#{what} is not JS RegExp syntax"}
    end
  end

  # JS semantics where PCRE has an option: code points, `$` only at the end, `.` excludes `\r`.
  defp pcre_options(flags) do
    [:unicode, :dollar_endonly, {:newline, :anycrlf}] ++
      for(
        {flag, opt} <- [{?i, :caseless}, {?m, :multiline}, {?s, :dotall}, {?y, :anchored}],
        flag in String.to_charlist(flags),
        do: opt
      )
  end

  @doc false
  # A JS regex returned by the driver: the `Regex` with the same meaning, else the `RegExp`.
  def parse(source, flags) do
    re = %__MODULE__{source: source, flags: flags}

    with true <- flags |> String.to_charlist() |> Enum.all?(&(&1 in ~c"imsu")),
         {:ok, ^source} <- js_to_pcre(source, String.contains?(flags, "u")),
         nil <- pcre_only(source, String.contains?(flags, "u"), false),
         {:ok, regex} <- Regex.compile(source, flags) do
      regex
    else
      _ -> re
    end
  end

  # JS source -> PCRE source: `[^]`/`[]`, a literal `[` in a class, `\uXXXX`/`\u{...}` and
  # identity escapes (`\A` is `A` in JS) differ.
  @js_letter_escapes ~c"bBcdDfknpPrsStvwWx"

  defp js_to_pcre(source, unicode) do
    {:ok, js_to_pcre(source, unicode, false, "")}
  catch
    {:error, reason} -> {:error, reason}
  end

  defp js_to_pcre(<<"[^]", rest::binary>>, unicode, false, acc), do: js_to_pcre(rest, unicode, false, acc <> "[\\s\\S]")
  defp js_to_pcre(<<"[]", rest::binary>>, unicode, false, acc), do: js_to_pcre(rest, unicode, false, acc <> "(?!)")
  defp js_to_pcre(<<?[, rest::binary>>, unicode, false, acc), do: js_to_pcre(rest, unicode, true, acc <> "[")
  defp js_to_pcre(<<?[, rest::binary>>, unicode, true, acc), do: js_to_pcre(rest, unicode, true, acc <> "\\[")
  defp js_to_pcre(<<?], rest::binary>>, unicode, true, acc), do: js_to_pcre(rest, unicode, false, acc <> "]")

  defp js_to_pcre(<<"\\u", hi::binary-4, "\\u", lo::binary-4, rest::binary>> = all, unicode, in_class, acc) do
    with {:ok, h} when h in 0xD800..0xDBFF <- hex(hi),
         {:ok, l} when l in 0xDC00..0xDFFF <- hex(lo) do
      cp = 0x10000 + (h - 0xD800) * 0x400 + (l - 0xDC00)
      js_to_pcre(rest, unicode, in_class, acc <> Regex.escape(<<cp::utf8>>))
    else
      _ -> js_to_pcre_u(all, unicode, in_class, acc)
    end
  end

  defp js_to_pcre(<<"\\u", _::binary>> = all, unicode, in_class, acc), do: js_to_pcre_u(all, unicode, in_class, acc)

  defp js_to_pcre(<<"\\x", h1, h2, rest::binary>>, unicode, in_class, acc)
       when h1 in ~c"0123456789abcdefABCDEF" and h2 in ~c"0123456789abcdefABCDEF",
       do: js_to_pcre(rest, unicode, in_class, acc <> "\\x" <> <<h1, h2>>)

  defp js_to_pcre(<<"\\x", rest::binary>>, unicode, in_class, acc), do: js_to_pcre(rest, unicode, in_class, acc <> "x")

  defp js_to_pcre(<<"\\v", rest::binary>>, unicode, in_class, acc),
    do: js_to_pcre(rest, unicode, in_class, acc <> "\\x0B")

  defp js_to_pcre(<<?\\, c, rest::binary>>, false, in_class, acc) when c in ~c"pP",
    do: js_to_pcre(rest, false, in_class, acc <> <<c>>)

  defp js_to_pcre(<<?\\, c, rest::binary>>, unicode, in_class, acc)
       when (c in ?a..?z or c in ?A..?Z) and c not in @js_letter_escapes,
       do: js_to_pcre(rest, unicode, in_class, acc <> <<c>>)

  defp js_to_pcre(<<?\\, c::utf8, rest::binary>>, unicode, in_class, acc),
    do: js_to_pcre(rest, unicode, in_class, <<acc::binary, ?\\, c::utf8>>)

  defp js_to_pcre(<<c::utf8, rest::binary>>, unicode, in_class, acc),
    do: js_to_pcre(rest, unicode, in_class, <<acc::binary, c::utf8>>)

  defp js_to_pcre(<<>>, _unicode, _in_class, acc), do: acc

  defp js_to_pcre_u(<<"\\u{", rest::binary>>, true, in_class, acc) do
    with [digits, rest] <- String.split(rest, "}", parts: 2),
         {:ok, cp} <- hex(digits) do
      js_to_pcre(rest, true, in_class, acc <> escape_code_point(cp))
    else
      _ -> throw({:error, "an invalid \\u{...} escape"})
    end
  end

  defp js_to_pcre_u(<<"\\u", digits::binary-4, rest::binary>> = all, unicode, in_class, acc) do
    case hex(digits) do
      {:ok, cp} -> js_to_pcre(rest, unicode, in_class, acc <> escape_code_point(cp))
      :error -> js_to_pcre_u_identity(all, unicode, in_class, acc)
    end
  end

  defp js_to_pcre_u(all, unicode, in_class, acc), do: js_to_pcre_u_identity(all, unicode, in_class, acc)

  defp js_to_pcre_u_identity(<<"\\u", rest::binary>>, false, in_class, acc),
    do: js_to_pcre(rest, false, in_class, acc <> "u")

  defp js_to_pcre_u_identity(_all, true, _in_class, _acc), do: throw({:error, "an invalid \\u escape"})

  defp escape_code_point(cp) when cp in 0xD800..0xDFFF, do: throw({:error, "a lone surrogate"})
  defp escape_code_point(cp) when cp > 0x10FFFF, do: throw({:error, "an invalid \\u{...} escape"})
  defp escape_code_point(cp), do: Regex.escape(<<cp::utf8>>)

  defp hex(digits) do
    if digits != "" and String.match?(digits, ~r/^[0-9a-fA-F]+$/),
      do: {:ok, String.to_integer(digits, 16)},
      else: :error
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

  defimpl String.Chars do
    def to_string(re), do: PlaywrightEx.RegExp.to_string(re)
  end

  # JSON.stringify(re) is "{}".
  defimpl JSON.Encoder do
    def encode(_re, _encoder), do: "{}"
  end
end
