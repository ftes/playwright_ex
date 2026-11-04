# upstream: playwright/_impl/_str_utils.py (subset)
defmodule Playwright.Impl.StrUtils do
  alias Playwright.Impl.Errors.Error

  # upstream: _str_utils.py:22
  def escape_regex_flags(pattern) do
    flags = ""
    flags = if :caseless in pattern.opts, do: flags <> "i", else: flags
    flags = if :dotall in pattern.opts, do: flags <> "s", else: flags
    flags = if :multiline in pattern.opts, do: flags <> "m", else: flags

    if Enum.any?(pattern.opts, &(&1 not in [:caseless, :dotall, :multiline, :unicode])),
      do:
        raise(
          Error.new("Unexpected Regex option, only multiline, caseless and dotall are supported.")
        )

    flags
  end

  # upstream: _str_utils.py:59
  def escape_regex_for_selector(text) do
    # Even number of backslashes followed by the quote -> insert a backslash.
    "/" <>
      (Regex.replace(~r/(^|[^\\])(\\\\)*(["'`])/, Regex.source(text), "\\1\\2\\\\\\3")
       |> String.replace(">>", "\\>\\>")) <>
      "/" <> escape_regex_flags(text)
  end

  # upstream: _str_utils.py:71
  def escape_for_text_selector(text, exact \\ nil, _case_sensitive \\ nil) do
    if is_struct(text, Regex),
      do: escape_regex_for_selector(text),
      else: JSON.encode!(text) <> if(exact, do: "s", else: "i")
  end

  # upstream: _str_utils.py:79
  def escape_for_attribute_selector(value, exact \\ nil) do
    if is_struct(value, Regex) do
      escape_regex_for_selector(value)
    else
      # TODO: this should actually be
      #   cssEscape(value).replace(/\\ /g, ' ')
      # However, our attribute selectors do not conform to CSS parsing spec,
      # so we escape them differently.
      ~s(") <>
        (value |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))) <>
        ~s(") <>
        if(exact, do: "s", else: "i")
    end
  end
end
