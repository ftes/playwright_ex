defmodule PlaywrightEx.Isomorphic.StringUtils do
  @upstream "packages/isomorphic/stringUtils.ts"
  @moduledoc """
  Port of `#{@upstream}`: the selector escaping that locators need, the case helpers of the
  locator generators and `normalize_white_space/1`. `RegExp` is a `Regex` or a
  `PlaywrightEx.RegExp`; `String(re)` is `/source/flags` as in JS.
  """

  alias PlaywrightEx.RegExp

  # JS `\s` and `trim()`, the same set (WhiteSpace and LineTerminator). PCRE's `\s` differs: it
  # also matches U+0085 and misses U+FEFF.
  @js_white_space "[\\x{09}-\\x{0d}\\x{20}\\x{a0}\\x{1680}\\x{2000}-\\x{200a}\\x{2028}\\x{2029}\\x{202f}\\x{205f}\\x{3000}\\x{feff}]"

  def escape_with_quotes(text, char \\ "'") do
    stringified = JSON.encode!(text)
    escaped_text = stringified |> String.slice(1..-2//1) |> String.replace(~S(\"), ~S("))

    case char do
      "'" -> char <> String.replace(escaped_text, "'", "\\'") <> char
      "\"" -> char <> String.replace(escaped_text, "\"", "\\\"") <> char
      "`" -> char <> String.replace(escaped_text, "`", "\\`") <> char
      _ -> raise "Invalid escape char"
    end
  end

  def escape_template_string(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("`", "\\`")
    |> String.replace("${", "\\${")
  end

  # isString  -- ported as is_binary/1

  def to_title_case(name) do
    {first, rest} = String.split_at(name, 1)
    String.upcase(first) <> rest
  end

  def to_snake_case(name) do
    # E.g. ignoreHTTPSErrors => ignore_https_errors.
    name
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
    |> String.replace(~r/([A-Z])([A-Z][a-z])/, "\\1_\\2")
    |> String.downcase()
  end

  # formatObject, formatObjectOrVoid, quoteCSSAttributeValue  -- not ported: codegen
  # let normalizedWhitespaceCache: Map<string, string> | undefined;  -- not ported: an optimization
  # cacheNormalizedWhitespaces  -- not ported: only the injected recorder enables the cache

  def normalize_white_space(text) do
    # let result = normalizedWhitespaceCache?.get(text);  -- not ported
    text
    |> String.replace(~r/[\x{200b}\x{00ad}]/u, "")
    |> String.replace(~r/\A#{@js_white_space}+|#{@js_white_space}+\z/u, "")
    |> String.replace(~r/#{@js_white_space}+/u, " ")

    # normalizedWhitespaceCache?.set(text, result);  -- not ported
  end

  def normalize_escaped_regex_quotes(source) do
    # This function reverses the effect of escapeRegexForSelector below.
    # Odd number of backslashes followed by the quote -> remove unneeded backslash.
    String.replace(source, ~r/(^|[^\\])(\\\\)*\\(['"`])/, "\\1\\2\\3")
  end

  defp escape_regex_for_selector(re) do
    # Unicode mode does not allow "identity character escapes", so we do not escape and
    # hope that it does not contain quotes and/or >> signs.
    # https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Regular_expressions/Character_escape
    # Upstream to-do: rework RE usages in internal selectors away from literal representation to json, e.g. {source,flags}.
    if String.contains?(RegExp.from_regex(re).flags, ["u", "v"]) do
      regex_to_string(re)
    else
      # Even number of backslashes followed by the quote -> insert a backslash.
      re
      |> regex_to_string()
      |> String.replace(~r/(^|[^\\])(\\\\)*(["'`])/, "\\1\\2\\\\\\3")
      |> String.replace(">>", "\\>\\>")
    end
  end

  def escape_for_text_selector(text, exact) do
    if not is_binary(text),
      do: escape_regex_for_selector(text),
      else: "#{JSON.encode!(text)}#{if exact, do: "s", else: "i"}"
  end

  def escape_for_attribute_selector(value, exact) do
    if not is_binary(value) do
      escape_regex_for_selector(value)
    else
      # Upstream to-do: this should actually be
      #   cssEscape(value).replace(/\\ /g, ' ')
      # However, our attribute selectors do not conform to CSS parsing spec,
      # so we escape them differently.
      ~s("#{value |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))}"#{if exact, do: "s", else: "i"})
    end
  end

  def trim_string(input, cap, suffix \\ "") do
    # `input.length` counts UTF-16 units, `[...input]` code points: both checks are on code points here.
    chars = String.codepoints(input)

    if length(chars) <= cap,
      do: input,
      else: Enum.join(Enum.take(chars, cap - length(String.codepoints(suffix)))) <> suffix
  end

  def trim_string_with_ellipsis(input, cap) do
    trim_string(input, cap, "\u2026")
  end

  # truncateDataUrl, escapeRegExp, escapeHTMLAttribute  -- not ported

  def escape_html(s), do: String.replace(s, ~r/[&<]/u, &if(&1 == "&", do: "&amp;", else: "&lt;"))
  # longestCommonSubstring, parseRegex, tomlBasicString, tomlArray, tomlMultilineBasicString  -- not ported

  def strip_ansi_escapes(str) do
    # ansiRegex (not a module attribute: OTP 28 cannot store a compiled regex in one).
    Regex.replace(
      ~r/([\x{1B}\x{9B}][[\]()#?]*(?:(?:(?:[a-zA-Z\d]*(?:;[-a-zA-Z\d\/#&.:=?%@~_]*)*)?\x{07})|(?:(?:\d{0,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-ntqry=><~])))/u,
      str,
      ""
    )
  end

  # String(re): JS escapes `/` in the source (`~r/a\/b/` has the source "a/b").
  defp regex_to_string(re), do: RegExp.to_string(RegExp.from_regex(re))
end
