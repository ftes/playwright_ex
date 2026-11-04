defmodule PlaywrightEx.Isomorphic.StringUtils do
  @upstream "packages/isomorphic/stringUtils.ts"
  @moduledoc """
  Port of `#{@upstream}`: the selector escaping that locators need. `RegExp` is `Regex`;
  `String(re)` is `/source/flags` as in JS.
  """

  alias PlaywrightEx.Protocol.Serializers

  # escapeWithQuotes, escapeTemplateString  -- not ported: codegen
  # isString  -- ported as is_binary/1
  # toTitleCase, toSnakeCase, formatObject, formatObjectOrVoid, quoteCSSAttributeValue  -- not ported: codegen
  # cacheNormalizedWhitespaces, normalizeWhiteSpace, normalizeEscapedRegexQuotes  -- not ported: locator parsing

  defp escape_regex_for_selector(re) do
    # Unicode mode does not allow "identity character escapes", so we do not escape and
    # hope that it does not contain quotes and/or >> signs.
    # https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Regular_expressions/Character_escape
    # Upstream to-do: rework RE usages in internal selectors away from literal representation to json, e.g. {source,flags}.
    if :unicode in Regex.opts(re) do
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

  # truncateDataUrl, escapeRegExp, escapeHTMLAttribute, escapeHTML  -- not ported
  # longestCommonSubstring, parseRegex, tomlBasicString, tomlArray, tomlMultilineBasicString, stripAnsiEscapes  -- not ported

  # String(re)
  defp regex_to_string(re), do: "/#{Regex.source(re)}/#{Serializers.regex_flags(re)}"
end
