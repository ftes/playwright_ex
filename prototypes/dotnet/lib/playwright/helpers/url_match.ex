defmodule Playwright.Helpers.URLMatch do
  @moduledoc "upstream: Helpers/URLMatch.cs (C# object initializer `new URLMatch { glob = .. }` -> struct)"

  # https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_expressions#escaping
  @escape_glob_chars ~c"$^+.*()|\\?{}[]"

  defstruct [:re, :func, :glob, :base_url, is_web_socket_url: false]

  # upstream: Helpers/URLMatch.cs:47
  def match(%__MODULE__{} = this, url) do
    match_impl(url, this.re, this.func, this.glob, this.base_url, this.is_web_socket_url)
  end

  # upstream: Helpers/URLMatch.cs:52
  defp match_impl(url, re, func, glob, base_url, is_web_socket_url) do
    cond do
      re != nil ->
        Regex.match?(re, url)

      func != nil ->
        func.(url)

      glob != nil ->
        if glob == "" do
          true
        else
          match = resolve_glob_to_regex_pattern(base_url, glob, is_web_socket_url)
          Regex.match?(Regex.compile!(match), url)
        end

      true ->
        true
    end
  end

  # upstream: Helpers/URLMatch.cs:89
  def construct_url_based_on_base_url(base_url, url) do
    try do
      elem(resolve_base_url(base_url, url), 0)
    rescue
      _ -> url
    end
  end

  # upstream: Helpers/URLMatch.cs:101
  def glob_to_regex_pattern(glob) when glob in [nil, ""], do: nil

  def glob_to_regex_pattern(glob) do
    chars = String.to_charlist(glob)
    tokens = glob_tokens(chars, nil, false, ["^"])
    Enum.join(Enum.reverse(["$" | tokens]))
  end

  # The C# `for (int i ...)` loop with look-behind/ahead becomes a recursive walk; `prev` is `glob[i - 1]`.
  defp glob_tokens([], _prev, _in_group, tokens), do: tokens

  defp glob_tokens([?\\, c | rest], _prev, in_group, tokens) do
    glob_tokens(rest, c, in_group, [if(c in @escape_glob_chars, do: "\\" <> <<c>>, else: <<c>>) | tokens])
  end

  defp glob_tokens([?* | _] = chars, prev, in_group, tokens) do
    {stars, rest} = Enum.split_while(chars, &(&1 == ?*))
    char_before = prev || 0

    cond do
      length(stars) > 1 and match?([?/ | _], rest) ->
        token = if char_before == ?/, do: "((.+/)|)", else: "(.*/)"
        glob_tokens(tl(rest), ?/, in_group, [token | tokens])

      length(stars) > 1 ->
        glob_tokens(rest, ?*, in_group, ["(.*)" | tokens])

      true ->
        glob_tokens(rest, ?*, in_group, ["([^/]*)" | tokens])
    end
  end

  defp glob_tokens([c | rest], _prev, in_group, tokens) do
    case c do
      ?{ -> glob_tokens(rest, c, true, ["(" | tokens])
      ?} -> glob_tokens(rest, c, false, [")" | tokens])
      ?, when in_group -> glob_tokens(rest, c, in_group, ["|" | tokens])
      ?, -> glob_tokens(rest, c, in_group, ["\\," | tokens])
      _ -> glob_tokens(rest, c, in_group, [if(c in @escape_glob_chars, do: "\\" <> <<c>>, else: <<c>>) | tokens])
    end
  end

  # upstream: Helpers/URLMatch.cs:203 (ToWebSocketBaseURL / ResolveGlobBase token mapping not ported)
  def resolve_glob_to_regex_pattern(base_url, glob, _is_web_socket_url) do
    glob = if String.starts_with?(glob, "*"), do: glob, else: elem(resolve_base_url(base_url, glob), 0)
    glob_to_regex_pattern(glob)
  end

  # upstream: Helpers/URLMatch.cs:280 (simplified: System.Uri -> URI.merge)
  defp resolve_base_url(base_url, url) when base_url in [nil, ""], do: {url, nil}
  defp resolve_base_url(base_url, url), do: {URI.to_string(URI.merge(base_url, url)), nil}
end
