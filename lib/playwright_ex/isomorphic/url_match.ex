defmodule PlaywrightEx.Isomorphic.UrlMatch do
  @upstream "packages/isomorphic/urlMatch.ts"
  @moduledoc """
  Port of `#{@upstream}`: matching URLs against globs, regexes and functions.

  Deviations: globs become regexes through the driver (`LocalUtils.globToRegex`, PLAN
  Decisions), so the functions that resolve globs take the `LocalUtils` as first argument.
  `RegExp` is `Regex`; a function matcher gets the URL string (Elixir has no `URL` class, as
  in the Python, Java and .NET clients). `URLPattern` has no Elixir counterpart.
  """

  alias PlaywrightEx.Client.LocalUtils
  alias PlaywrightEx.Protocol.Serializers

  # isHttpUrl  -- not ported: unused
  # globToRegexPattern  -- not ported: LocalUtils.globToRegex (PLAN)
  # isRegExp  -- ported as is_struct(match, Regex)
  # isURLPattern, serializeURLPattern  -- not ported: URLPattern

  def serialize_url_match(match) do
    cond do
      is_binary(match) -> %{glob: match}
      is_struct(match, Regex) -> %{regexSource: Regex.source(match), regexFlags: Serializers.regex_flags(match)}
      # if (isURLPattern(match)) return { urlPattern: serializeURLPattern(match) };  -- not ported: URLPattern
      # Functions cannot be serialized
      true -> nil
    end
  end

  # deserializeURLPattern, deserializeURLMatch  -- not ported: URLPattern

  def url_matches_equal(match1, match2) do
    if is_struct(match1, Regex) and is_struct(match2, Regex),
      do: Regex.source(match1) == Regex.source(match2) and Regex.opts(match1) == Regex.opts(match2),
      else: match1 == match2
  end

  def url_matches(local_utils, base_url, url_string, match, web_socket_url \\ nil) do
    cond do
      match == nil or match == "" ->
        true

      is_binary(match) ->
        url_matches(
          local_utils,
          base_url,
          url_string,
          Regex.compile!(resolve_glob_to_regex_pattern(local_utils, base_url, match, web_socket_url)),
          web_socket_url
        )

      is_struct(match, Regex) ->
        # match.lastIndex = 0;  -- n/a: Elixir regexes are stateless
        Regex.match?(match, url_string)

      true ->
        url = parse_url(url_string)

        cond do
          !url -> false
          # if (isURLPattern(match)) return match.test(url.href);  -- not ported: URLPattern
          not is_function(match, 1) -> raise "url parameter should be string, RegExp, URLPattern or function"
          true -> match.(url)
        end
    end
  end

  def resolve_glob_to_regex_pattern(local_utils, base_url, glob, web_socket_url \\ nil) do
    # if (webSocketUrl) baseURL = toWebSocketBaseUrl(baseURL); glob = resolveGlobBase(baseURL, glob);
    # return globToRegexPattern(glob);  -- ported as LocalUtils.globToRegex (PLAN)
    LocalUtils.glob_to_regex(local_utils, %{glob: glob, baseURL: base_url, webSocketUrl: web_socket_url})
  end

  # toWebSocketBaseUrl, resolveGlobBase  -- not ported: LocalUtils.globToRegex (PLAN)

  # `new URL(url)`, but the matcher gets the string (see the moduledoc).
  defp parse_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme}} when is_binary(scheme) -> url
      _ -> nil
    end
  end

  def construct_url_based_on_base_url(base_url, given_url) do
    resolve_base_url(base_url, given_url).resolved
  rescue
    _ -> given_url
  end

  defp resolve_base_url(base_url, given_url) do
    url = new_url(given_url, base_url)
    resolved = url_to_string(url)
    # Schema and domain are case-insensitive.
    case_insensitive_prefix = url_to_string(%{url | path: nil, query: nil, fragment: nil, userinfo: nil})
    %{resolved: resolved, caseInsensitivePart: case_insensitive_prefix}
  rescue
    _ -> %{resolved: given_url}
  end

  # `new URL(url, base)`: raises unless the result is absolute.
  defp new_url(url, nil), do: absolute!(URI.new!(url))
  defp new_url(url, base), do: absolute!(URI.merge(absolute!(URI.new!(base)), url))

  defp absolute!(%URI{scheme: scheme} = uri) when is_binary(scheme), do: uri
  defp absolute!(_uri), do: raise(ArgumentError, "Invalid URL")

  # `url.toString()`: WHATWG URLs lowercase scheme and host and have a "/" path when it is empty.
  defp url_to_string(%URI{} = uri) do
    host = uri.host && String.downcase(uri.host)
    path = if uri.host != nil and uri.path in [nil, ""], do: "/", else: uri.path
    URI.to_string(%{uri | scheme: String.downcase(uri.scheme), host: host, path: path})
  end
end
