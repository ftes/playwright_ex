defmodule PlaywrightEx.Client.Network do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of the top-level functions of `#{@upstream}`. Its classes are modules named after them
  (`PlaywrightEx.Client.Request`, `PlaywrightEx.Client.Response`, `PlaywrightEx.Client.RawHeaders`).
  """
  alias PlaywrightEx.Protocol.Serializers

  def to_clear_cookies_params(options) do
    %{
      name: if(is_binary(options[:name]), do: options.name),
      nameRegexSource: if(is_struct(options[:name], Regex), do: Regex.source(options.name)),
      nameRegexFlags: if(is_struct(options[:name], Regex), do: Serializers.regex_flags(options.name)),
      domain: if(is_binary(options[:domain]), do: options.domain),
      domainRegexSource: if(is_struct(options[:domain], Regex), do: Regex.source(options.domain)),
      domainRegexFlags: if(is_struct(options[:domain], Regex), do: Serializers.regex_flags(options.domain)),
      path: if(is_binary(options[:path]), do: options.path),
      pathRegexSource: if(is_struct(options[:path], Regex), do: Regex.source(options.path)),
      pathRegexFlags: if(is_struct(options[:path], Regex), do: Serializers.regex_flags(options.path))
    }
  end

  # Route, WebSocketRoute, WebSocketRouteHandler, WebSocket, RouteHandler  -- not ported: routing

  def validate_headers(headers) do
    for {key, value} <- headers, value != nil, !is_binary(value) do
      raise ~s(Expected value of header "#{key}" to be String, but "#{js_typeof(value)}" is found.)
    end

    nil
  end

  defp js_typeof(value) when is_number(value), do: "number"
  defp js_typeof(value) when is_boolean(value), do: "boolean"
  defp js_typeof(value) when is_function(value), do: "function"
  defp js_typeof(_value), do: "object"
end
