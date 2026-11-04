defmodule Playwright.Helpers.RegexOptionsExtensions do
  @moduledoc "upstream: Helpers/RegexOptionsExtensions.cs (System.Text.RegularExpressions.Regex -> Elixir Regex)"

  # upstream: Helpers/RegexOptionsExtensions.cs:41
  def get_source_and_flags(%Regex{} = regex) do
    source = Regex.source(regex)
    options = Regex.opts(regex)
    # Leading inline flags ("(?i)") are left in the source; Elixir users pass ~r/../i instead.
    {source, get_inline_flags(options)}
  end

  # upstream: Helpers/RegexOptionsExtensions.cs:80
  def get_inline_flags(options) do
    flags = ""
    flags = if :caseless in options, do: flags <> "i", else: flags
    flags = if :dotall in options, do: flags <> "s", else: flags
    flags = if :multiline in options, do: flags <> "m", else: flags

    if Enum.any?(options, &(&1 not in [:caseless, :dotall, :multiline, :unicode, :ucp])) do
      raise ArgumentError, "Unsupported RegularExpression flags"
    end

    flags
  end
end
