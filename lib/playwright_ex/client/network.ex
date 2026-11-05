defmodule PlaywrightEx.Client.Network do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of the top-level functions of `#{@upstream}`. Its classes are modules named after them
  (`PlaywrightEx.Client.Request`, `PlaywrightEx.Client.Response`, `PlaywrightEx.Client.Route`,
  `PlaywrightEx.Client.WebSocketRoute`, `PlaywrightEx.Client.WebSocketRouteHandler`,
  `PlaywrightEx.Client.WebSocket`, `PlaywrightEx.Client.RouteHandler`, `PlaywrightEx.Client.RawHeaders`).
  """
  alias PlaywrightEx.RegExp

  def to_clear_cookies_params(options) do
    {name_source, name_flags} = RegExp.to_js(options[:name])
    {domain_source, domain_flags} = RegExp.to_js(options[:domain])
    {path_source, path_flags} = RegExp.to_js(options[:path])

    %{
      name: if(is_binary(options[:name]), do: options.name),
      nameRegexSource: name_source,
      nameRegexFlags: name_flags,
      domain: if(is_binary(options[:domain]), do: options.domain),
      domainRegexSource: domain_source,
      domainRegexFlags: domain_flags,
      path: if(is_binary(options[:path]), do: options.path),
      pathRegexSource: path_source,
      pathRegexFlags: path_flags
    }
  end

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
