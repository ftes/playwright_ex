# upstream: packages/isomorphic/stringUtils.ts (subset)
defmodule PlaywrightJS.Isomorphic.StringUtils do
  # upstream: stringUtils.ts:37
  def is_string(obj) do
    is_binary(obj)
  end

  # upstream: stringUtils.ts:86
  def normalize_white_space(text) do
    text |> String.replace(~r/[\x{200b}\x{00ad}]/u, "") |> String.trim() |> String.replace(~r/\s+/u, " ")
  end

  # upstream: stringUtils.ts:101
  defp escape_regex_for_selector(re) do
    # Unicode mode does not allow "identity character escapes", so we do not escape and
    # hope that it does not contain quotes and/or >> signs.
    if :unicode in Regex.opts(re) do
      regex_to_string(re)
    else
      # Even number of backslashes followed by the quote -> insert a backslash.
      regex_to_string(re) |> String.replace(~r/(^|[^\\])(\\\\)*(["'`])/, "\\1\\2\\\\\\3") |> String.replace(">>", "\\>\\>")
    end
  end

  # upstream: stringUtils.ts:112
  def escape_for_text_selector(text, exact) do
    if !is_binary(text), do: escape_regex_for_selector(text), else: "#{JSON.encode!(text)}#{if exact, do: "s", else: "i"}"
  end

  # upstream: stringUtils.ts:118
  def escape_for_attribute_selector(value, exact) do
    if !is_binary(value) do
      escape_regex_for_selector(value)
    else
      # TODO: this should actually be
      #   cssEscape(value).replace(/\\ /g, ' ')
      # However, our attribute selectors do not conform to CSS parsing spec,
      # so we escape them differently.
      "\"#{value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}\"#{if exact, do: "s", else: "i"}"
    end
  end

  # `String(re)` for an Elixir regex: "/source/flags"
  def regex_to_string(re), do: "/" <> Regex.source(re) <> "/" <> regex_flags(re)

  # `re.flags` for an Elixir regex
  def regex_flags(re) do
    opts = Regex.opts(re)
    for {opt, flag} <- [dotall: "s", caseless: "i", multiline: "m", unicode: "u"], opt in opts, into: "", do: flag
  end
end
