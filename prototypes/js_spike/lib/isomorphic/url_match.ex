# upstream: packages/isomorphic/urlMatch.ts (subset)
defmodule PlaywrightJS.Isomorphic.UrlMatch do
  # upstream: urlMatch.ts:95
  defp is_reg_exp(obj) do
    is_struct(obj, Regex)
  end

  # upstream: urlMatch.ts:132
  def serialize_url_match(match) do
    cond do
      is_binary(match) -> %{glob: match}
      is_reg_exp(match) -> %{regexSource: Regex.source(match), regexFlags: PlaywrightJS.Isomorphic.StringUtils.regex_flags(match)}
      # if (isURLPattern(match)) ...  -- not ported
      # Functions cannot be serialized
      true -> nil
    end
  end

  # upstream: urlMatch.ts:174
  def url_matches_equal(match1, match2) do
    if is_reg_exp(match1) and is_reg_exp(match2),
      do: Regex.source(match1) == Regex.source(match2) and Regex.opts(match1) == Regex.opts(match2),
      else: match1 == match2
  end

  # upstream: urlMatch.ts:180
  def url_matches(base_url, url_string, match, _web_socket_url \\ false) do
    cond do
      match == nil or match == "" -> true
      # if (isString(match)) match = new RegExp(resolveGlobToRegexPattern(baseURL, match, webSocketUrl));  -- not ported: globs
      is_binary(match) -> raise "glob URL matching: not ported (#{inspect(base_url)})"
      is_reg_exp(match) -> Regex.match?(match, url_string)
      true -> url_matches_url(url_string, match)
    end
  end

  defp url_matches_url(url_string, match) do
    url = parse_url(url_string)

    cond do
      !url -> false
      # if (isURLPattern(match)) return match.test(url.href);  -- not ported
      !is_function(match, 1) -> raise "url parameter should be string, RegExp, URLPattern or function"
      true -> match.(url)
    end
  end

  # upstream: urlMatch.ts:270
  defp parse_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme} = uri} when scheme != nil -> uri
      _ -> nil
    end
  end

  # upstream: urlMatch.ts:278
  def construct_url_based_on_base_url(base_url, given_url) do
    resolve_base_url(base_url, given_url).resolved
  rescue
    _ -> given_url
  end

  # upstream: urlMatch.ts:286
  defp resolve_base_url(base_url, given_url) do
    url = if base_url, do: URI.merge(base_url, given_url), else: URI.new!(given_url)
    resolved = URI.to_string(url)
    # Schema and domain are case-insensitive.
    case_insensitive_prefix = "#{url.scheme}://#{url.host}"
    %{resolved: resolved, caseInsensitivePart: case_insensitive_prefix}
  rescue
    _ -> %{resolved: given_url}
  end
end
