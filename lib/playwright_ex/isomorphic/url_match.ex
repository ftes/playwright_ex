defmodule PlaywrightEx.Isomorphic.UrlMatch do
  @upstream "packages/isomorphic/urlMatch.ts"
  @moduledoc """
  Port of `#{@upstream}`: matching URLs against globs, regexes and functions.

  Deviations: `RegExp` is `Regex`; a function matcher gets the URL string, not a parsed `URL`
  (as in the Python, Java and .NET clients). `URLPattern` has no Elixir counterpart. `new URL()`
  is `PlaywrightEx.Isomorphic.URL`.
  """

  alias PlaywrightEx.Isomorphic.URL
  alias PlaywrightEx.Protocol.Serializers

  # isHttpUrl  -- not ported: unused

  # https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_expressions#escaping
  @escaped_chars ["$", "^", "+", ".", "*", "(", ")", "|", "\\", "?", "{", "}", "[", "]"]

  def glob_to_regex_pattern(glob) do
    # `glob[i]`: the glob as a tuple of code points, `nil` past either end.
    glob_to_regex_pattern(glob, List.to_tuple(String.codepoints(glob)), 0, ["^"], false)
  end

  defp glob_to_regex_pattern(glob, chars, i, tokens, in_group) do
    case {at(chars, i), at(chars, i + 1)} do
      {nil, _} ->
        if in_group, do: raise("Invalid glob pattern #{JSON.encode!(glob)}: unmatched '{'")
        Enum.join(Enum.reverse(["$" | tokens]))

      {"\\", char} when char != nil ->
        token = if char in @escaped_chars, do: "\\" <> char, else: char
        glob_to_regex_pattern(glob, chars, i + 2, [token | tokens], in_group)

      {"*", _} ->
        char_before = at(chars, i - 1)
        # while (glob[i + 1] === '*') { starCount++; i++; }
        star_count = count_stars(chars, i + 1, 1)
        i = i + star_count - 1

        {token, i} =
          if star_count > 1 do
            char_after = at(chars, i + 1)
            # Match either /..something../ or /.
            cond do
              char_after == "/" and char_before == "/" -> {"((.+/)|)", i + 1}
              char_after == "/" -> {"(.*/)", i + 1}
              true -> {"(.*)", i}
            end
          else
            {"([^/]*)", i}
          end

        glob_to_regex_pattern(glob, chars, i + 1, [token | tokens], in_group)

      {"{", _} ->
        if in_group, do: raise("Invalid glob pattern #{JSON.encode!(glob)}: nested '{' is not supported")
        glob_to_regex_pattern(glob, chars, i + 1, ["(" | tokens], true)

      {"}", _} ->
        if !in_group, do: raise("Invalid glob pattern #{JSON.encode!(glob)}: unmatched '}'")
        glob_to_regex_pattern(glob, chars, i + 1, [")" | tokens], false)

      {",", _} ->
        token = if in_group, do: "|", else: "\\,"
        glob_to_regex_pattern(glob, chars, i + 1, [token | tokens], in_group)

      {c, _} ->
        token = if c in @escaped_chars, do: "\\" <> c, else: c
        glob_to_regex_pattern(glob, chars, i + 1, [token | tokens], in_group)
    end
  end

  defp at(chars, i), do: if(i >= 0 and i < tuple_size(chars), do: elem(chars, i))

  defp count_stars(chars, i, count) do
    if at(chars, i) == "*", do: count_stars(chars, i + 1, count + 1), else: count
  end

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

  def url_matches(base_url, url_string, match, web_socket_url \\ nil) do
    cond do
      match == nil or match == "" ->
        true

      is_binary(match) ->
        url_matches(
          base_url,
          url_string,
          Regex.compile!(resolve_glob_to_regex_pattern(base_url, match, web_socket_url)),
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
          # The matcher gets the URL string (see the moduledoc).
          true -> match.(url_string)
        end
    end
  end

  def resolve_glob_to_regex_pattern(base_url, glob, web_socket_url \\ nil) do
    base_url = if web_socket_url, do: to_web_socket_base_url(base_url), else: base_url
    glob = resolve_glob_base(base_url, glob)
    glob_to_regex_pattern(glob)
  end

  defp to_web_socket_base_url(base_url) do
    # Allow http(s) baseURL to match ws(s) urls. Schemes are case-insensitive,
    # same as elsewhere in this file, so 'HTTP://...' should be rewritten too.
    if base_url && Regex.match?(~r/^https?:\/\//i, base_url),
      do:
        Regex.replace(
          ~r/^https?/i,
          base_url,
          fn scheme -> if String.downcase(scheme) == "https", do: "wss", else: "ws" end,
          global: false
        ),
      else: base_url
  end

  defp resolve_glob_base(base_url, match) do
    if String.starts_with?(match, "*") do
      match
    else
      # Escaped `\\?` behaves the same as `?` in our glob patterns.
      match = String.replace(match, "\\\\?", "?")

      # Special case about: URLs as they are not relative to baseURL
      if String.starts_with?(match, ["about:", "data:", "chrome:", "edge:", "file:"]) do
        match
      else
        # Glob symbols may be escaped in the URL and some of them such as ? affect resolution,
        # so we replace them with safe components first. `tokenMap` is a list (newest first).
        {tokens, token_map} =
          match
          |> String.split("/")
          |> Enum.with_index()
          |> Enum.map_reduce([], fn {token, index}, token_map -> map_glob_token(token, index, token_map) end)

        relative_path = Enum.join(tokens, "/")
        result = resolve_base_url(base_url, relative_path)

        token_map
        |> Enum.reverse()
        |> Enum.reduce(result.resolved, fn {token, original}, resolved ->
          normalize = result[:caseInsensitivePart] != nil and String.contains?(result.caseInsensitivePart, token)
          replacement = if normalize, do: String.downcase(original), else: original
          # String.replace/4 with a string pattern inserts the replacement literally (JS needs the
          # function form for '$$', '$&', ...).
          String.replace(resolved, token, replacement, global: false)
        end)
      end
    end
  end

  defp map_glob_token(token, index, token_map) do
    cond do
      token in [".", "..", ""] ->
        {token, token_map}

      # Handle special case of http*://, note that the new schema has to be
      # a web schema so that slashes are properly inserted after domain.
      index == 0 and String.ends_with?(token, ":") ->
        # Replace any pattern with http:
        if String.contains?(token, ["*", "{"]),
          do: map_token(token, "http:", token_map),
          # Preserve explicit schema as is as it may affect trailing slashes after domain.
          else: {token, token_map}

      # Components without glob metacharacters are literal, so let them round-trip
      # through new URL() to preserve normalization (default ports such as :80/:443,
      # percent-encoding, IDN hosts). Only opaque tokens defeat that normalization.
      !Regex.match?(~r/[*?{}\\]/, token) ->
        {token, token_map}

      true ->
        case :binary.match(token, "?") do
          :nomatch ->
            map_token(token, "$_#{index}_$", token_map)

          {question_index, _} ->
            prefix = binary_part(token, 0, question_index)
            suffix = binary_part(token, question_index, byte_size(token) - question_index)
            {new_prefix, token_map} = map_token(prefix, "$_#{index}_$", token_map)
            {new_suffix, token_map} = map_token(suffix, "?$_#{index}_$", token_map)
            {new_prefix <> new_suffix, token_map}
        end
    end
  end

  defp map_token("", _replacement, token_map), do: {"", token_map}
  defp map_token(original, replacement, token_map), do: {replacement, [{replacement, original} | token_map]}

  defp parse_url(url) do
    URL.new(url)
  rescue
    _ -> nil
  end

  def construct_url_based_on_base_url(base_url, given_url) do
    resolve_base_url(base_url, given_url).resolved
  rescue
    _ -> given_url
  end

  defp resolve_base_url(base_url, given_url) do
    url = URL.new(given_url, base_url)
    resolved = URL.href(url)
    # Schema and domain are case-insensitive.
    case_insensitive_prefix = URL.origin(url)
    %{resolved: resolved, caseInsensitivePart: case_insensitive_prefix}
  rescue
    _ -> %{resolved: given_url}
  end
end
