defmodule PlaywrightEx.Isomorphic.ProtocolFormatter do
  @upstream "packages/isomorphic/protocolFormatter.ts"
  @moduledoc """
  Port of `#{@upstream}`: the title, subtitle, params and group of a protocol call from its
  metainfo (`PlaywrightEx.Protocol.Metainfo`), for the `pw:api` steps of `PlaywrightEx.Test`.

  `CallMetainfo` is a map with `type`, `method`, `params` (JS keys, as the client passes them to
  its channel), `title` and `subtitle`. `sdk_language` is `"javascript"` by default, as upstream's.
  `String(value)` is JS's: a list joins with `,`, a map is `[object Object]`. The params of
  `render_params_for_call/2` have string keys.
  """

  alias PlaywrightEx.Isomorphic.LocatorGenerators
  alias PlaywrightEx.Protocol.Metainfo
  alias PlaywrightEx.RegExp

  # export type CallMetainfo = { type, method, params?, title?, subtitle? };  -- a map

  def format_protocol_param(params, alternatives, sdk_language \\ nil) do
    case _format_protocol_param(params, alternatives, sdk_language) do
      nil -> nil
      value -> String.replace(value, "\n", "\\n")
    end
  end

  defp _format_protocol_param(nil, _alternatives, _sdk_language), do: nil

  defp _format_protocol_param(params, alternatives, sdk_language) do
    Enum.find_value(String.split(alternatives, "|"), fn name ->
      with :continue <- format_url(params, name),
           :continue <- format_time_number(params, name) do
        value = deep_param(params, name)

        cond do
          value == nil -> nil
          name == "selector" or String.ends_with?(name, ".selector") -> as_locator_description(sdk_language, value)
          true -> value
        end
      end
    end)
  end

  # `if (name === 'url') { try { const urlObject = new URL(params[name]); ... } catch { ... } }`:
  # `:continue` where it falls through.
  defp format_url(params, "url") do
    value = param(params, "url")

    case new_url(value) do
      %URI{scheme: "data"} -> "data:"
      %URI{scheme: scheme} when scheme in ["about", "chrome", "edge"] -> value
      %URI{} = url -> url_host(url) <> url_pathname(url) <> url_search(url)
      nil when value != nil -> js_string(value)
      nil -> :continue
    end
  end

  defp format_url(_params, _name), do: :continue

  # `new Date(params[name]).toString()`.
  # deviation: no time zone name (`(Central European Standard Time)`) after the offset: Erlang
  # knows the local offset only.
  defp format_time_number(params, "timeNumber") do
    case param(params, "timeNumber") do
      nil -> :continue
      ms -> date_to_string(trunc(ms))
    end
  end

  defp format_time_number(_params, _name), do: :continue

  defp date_to_string(ms) do
    utc = :calendar.system_time_to_universal_time(ms, :millisecond)
    local = :calendar.universal_time_to_local_time(utc)
    offset = div(:calendar.datetime_to_gregorian_seconds(local) - :calendar.datetime_to_gregorian_seconds(utc), 60)
    {{year, month, day} = date, {hour, minute, second}} = local
    weekday = Enum.at(~w(Mon Tue Wed Thu Fri Sat Sun), :calendar.day_of_the_week(date) - 1)
    month = Enum.at(~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec), month - 1)
    sign = if offset < 0, do: "-", else: "+"
    year = year |> Integer.to_string() |> String.pad_leading(4, "0")

    "#{weekday} #{month} #{pad(day)} #{year} #{pad(hour)}:#{pad(minute)}:#{pad(second)} " <>
      "GMT#{sign}#{pad(div(abs(offset), 60))}#{pad(rem(abs(offset), 60))}"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # `new URL(url)`, `nil` where it throws: an absolute URL has a scheme. `URI` is RFC 3986, not
  # WHATWG (see `PlaywrightEx.Isomorphic.URLMatch`).
  defp new_url(url) when is_binary(url) do
    if Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/, url) do
      uri = URI.parse(url)
      %{uri | scheme: String.downcase(uri.scheme)}
    end
  end

  defp new_url(_url), do: nil

  # `url.host`: lowercase, an IPv6 address in brackets (which `URI` drops), with the port unless
  # it is the scheme's default.
  defp url_host(%URI{host: nil}), do: ""

  defp url_host(%URI{host: host, port: port, scheme: scheme}) do
    host = String.downcase(host)
    host = if String.contains?(host, ":"), do: "[#{host}]", else: host
    if port == nil or port == URI.default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  # `url.pathname`: "/" for the empty path of a URL with a host.
  defp url_pathname(%URI{host: host, path: path}) when host != nil and path in [nil, ""], do: "/"
  defp url_pathname(%URI{path: path}), do: path || ""

  # `url.search`: "" for no or an empty query.
  defp url_search(%URI{query: query}) when query in [nil, ""], do: ""
  defp url_search(%URI{query: query}), do: "?" <> query

  defp deep_param(params, name) do
    current =
      Enum.reduce_while(String.split(name, "."), params, fn token, current ->
        if is_map(current) and not is_struct(current), do: {:cont, param(current, token)}, else: {:halt, nil}
      end)

    if current != nil, do: js_string(current)
  end

  def render_title_for_call(metadata, sdk_language \\ nil) do
    title_format = metadata[:title] || get_metainfo(metadata)[:title] || metadata.method

    Regex.replace(~r/\{([^}]+)\}/, title_format, fn full_match, p1 ->
      format_protocol_param(metadata[:params], p1, sdk_language) || full_match
    end)
  end

  def render_subtitle_for_call(metadata, sdk_language \\ nil) do
    subtitle_format = metadata[:subtitle] || get_metainfo(metadata)[:subtitle]

    if subtitle_format != nil do
      # `allParamsResolved`: each placeholder's param, the subtitle only when all resolve.
      params =
        for [p1] <- Regex.scan(~r/\{([^}]+)\}/, subtitle_format, capture: :all_but_first),
            into: %{},
            do: {p1, format_protocol_param(metadata[:params], p1, sdk_language)}

      if Enum.all?(params, fn {_p1, param} -> param != nil end),
        do: Regex.replace(~r/\{([^}]+)\}/, subtitle_format, fn _full_match, p1 -> params[p1] end)
    end
  end

  def render_full_title_for_call(metadata, sdk_language \\ nil) do
    title = render_title_for_call(metadata, sdk_language)
    subtitle = render_subtitle_for_call(metadata, sdk_language)
    if subtitle, do: "#{title} #{subtitle}", else: title
  end

  # export type ActionGroup = 'configuration' | 'route' | 'getter';  -- a string

  def get_action_group(metadata), do: get_metainfo(metadata)[:group]

  @k_max_param_length 200

  # Curated per-call parameters, defined by the "renderParams" lists in protocol.yml. Only the
  # arguments that say what the call actually did are reported, and only when they are
  # bounded in size: page content, evaluated expressions, request bodies and the like are
  # never reported, and neither are options that repeat their default on every call.
  def render_params_for_call(metadata, sdk_language \\ nil) do
    if params = metadata[:params] do
      locator = render_locator(param(params, "selector"), sdk_language)
      result = if locator != nil, do: %{"locator" => locator}, else: %{}

      result =
        Enum.reduce(get_metainfo(metadata)[:renderParams] || [], result, fn entry, result ->
          case render_param_entry(params, entry, sdk_language) do
            %{value: nil} -> result
            %{key: key, value: value} -> Map.put(result, key, value)
          end
        end)

      if map_size(result) > 0, do: result
    end
  end

  # Each entry is "[key=]path[:selector]": a dotted path into the call params, reported
  # under the last path segment unless an explicit key is given, with selector values
  # rendered as locators.
  defp render_param_entry(params, entry, sdk_language) do
    [spec | format] = String.split(entry, ":")

    {key, path} =
      case String.split(spec, "=", parts: 2) do
        [path] -> {path |> String.split(".") |> List.last(), path}
        [key, path] -> {key, path}
      end

    value =
      Enum.reduce_while(String.split(path, "."), params, fn token, value ->
        if is_map(value) and not is_struct(value), do: {:cont, param(value, token)}, else: {:halt, nil}
      end)

    cond do
      value == nil -> %{key: key, value: value}
      List.first(format) == "selector" -> %{key: key, value: render_locator(value, sdk_language)}
      is_binary(value) -> %{key: key, value: truncate_param(value)}
      true -> %{key: key, value: value}
    end
  end

  defp render_locator(selector, sdk_language) when is_binary(selector),
    do: truncate_param(as_locator_description(sdk_language, selector))

  defp render_locator(_selector, _sdk_language), do: nil

  # `value.length` and `substring` count UTF-16 code units. A UTF-8 string has at least as many
  # bytes as units: most are short enough to return as they are.
  def truncate_param(value) when byte_size(value) <= @k_max_param_length, do: value

  def truncate_param(value) do
    case :unicode.characters_to_binary(value, :utf8, :utf16) do
      utf16 when byte_size(utf16) > 2 * @k_max_param_length ->
        <<head::binary-size(2 * @k_max_param_length), _rest::binary>> = utf16
        # deviation: a surrogate pair cut in half loses its first half, which a string of
        # Elixir's (UTF-8) can't hold.
        head = with {:incomplete, converted, _half} <- :unicode.characters_to_binary(head, :utf16), do: converted
        head <> "…"

      utf16 when is_binary(utf16) ->
        value

      # Not UTF-8: by code points.
      _error ->
        if String.length(value) > @k_max_param_length,
          do: String.slice(value, 0, @k_max_param_length) <> "…",
          else: value
    end
  end

  # deviation: the last description is kept in the process: a call's subtitle and params render
  # the same selector, and the description costs about 12 µs.
  defp as_locator_description(sdk_language, selector) do
    key = {sdk_language || "javascript", selector}

    case Process.get(__MODULE__) do
      {^key, description} ->
        description

      _ ->
        description = LocatorGenerators.as_locator_description(elem(key, 0), selector)
        Process.put(__MODULE__, {key, description})
        description
    end
  end

  defp get_metainfo(metadata), do: Metainfo.get_metainfo(metadata) || %{}

  # `params[name]`: the params' keys are atoms (protocol.yml's names), or strings. `name` may be
  # any text in braces of a call's own title, so it is no new atom: a key that is not an atom yet
  # is in no params.
  defp param(params, name) do
    case Map.fetch(params, name) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(params, String.to_existing_atom(name))
        rescue
          ArgumentError -> nil
        end
    end
  end

  # `String(value)`.
  defp js_string(value) when is_list(value),
    do: Enum.map_join(value, ",", &if(&1 in [nil, :null], do: "", else: js_string(&1)))

  defp js_string(%RegExp{} = value), do: LocatorGenerators.js_string(value)
  defp js_string(value) when is_map(value), do: "[object Object]"
  defp js_string(:null), do: "null"
  defp js_string(value), do: LocatorGenerators.js_string(value)
end
