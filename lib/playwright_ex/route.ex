defmodule PlaywrightEx.Route do
  @moduledoc """
  Resolve a request intercepted by `PlaywrightEx.Page.route/4` or
  `PlaywrightEx.BrowserContext.route/4`.

  Handles carry their connection and registration timeout. Operations return
  `{:ok, result}` or `{:error, reason}` and accept `:connection` and `:timeout`
  overrides. Each callback may resolve its handle once. Returning without
  resolving it leaves the request paused until resolution or target closure.
  """

  alias PlaywrightEx.Routing

  @opaque t :: %__MODULE__{router: pid(), token: reference(), connection: GenServer.server(), timeout: timeout()}
  defstruct [:router, :token, :connection, :timeout]

  @doc """
  Serves a response without contacting the network.

  Options: `:status` (default 200), `:headers` (map or list of name/value pairs),
  `:content_type`, and `:body` (binary, default empty). Binary bodies are encoded
  internally, including non-UTF-8 data. Header names are case insensitive.
  Alternatively, supply `:json` (encoded with `JSON.encode!/1`, including `nil`
  and `false`) or `:path` (read from this Elixir host, including with remote
  browsers). These three body sources are mutually exclusive. JSON defaults to
  `application/json`; files infer content type from their extension, falling
  back to `application/octet-stream`. `:content_type` overrides these defaults.
  An unreadable file raises `File.Error`; unsupported JSON values raise an
  encoding error. Neither consumes the route handle.

  `:response` is deferred. Protocol-only options such as `:is_base64` are not
  accepted.
  """
  def fulfill(%__MODULE__{} = route, opts \\ []) do
    opts =
      validate!(route, opts,
        status: [type: :pos_integer, default: 200],
        headers: [type: :any, default: %{}],
        content_type: [type: :string],
        body: [type: :string],
        json: [type: :any],
        path: [type: :string]
      )

    {body, default_type} = fulfillment_body(opts)
    headers = headers(Keyword.fetch!(opts, :headers))
    content_type = opts[:content_type] || default_type
    headers = if content_type, do: Map.put(headers, "content-type", content_type), else: headers

    headers =
      if byte_size(body) > 0, do: Map.put_new(headers, "content-length", to_string(byte_size(body))), else: headers

    resolve(
      route,
      :fulfill,
      %{status: opts[:status], headers: header_array(headers), body: Base.encode64(body), is_base64: true},
      opts
    )
  end

  defp fulfillment_body(opts) do
    case Keyword.take(opts, [:body, :json, :path]) do
      [] -> {"", nil}
      [body: body] -> {body, nil}
      [json: value] -> {JSON.encode!(value), "application/json"}
      [path: path] -> {File.read!(path), MIME.from_path(path)}
      _ -> raise ArgumentError, "specify only one of :body, :json, or :path"
    end
  end

  @doc "Aborts the request. `:error_code` defaults to `\"failed\"` (Playwright network error code)."
  def abort(%__MODULE__{} = route, opts \\ []) do
    opts = validate!(route, opts, error_code: [type: :string, default: "failed"])
    resolve(route, :abort, %{error_code: opts[:error_code]}, opts)
  end

  @doc """
  Sends the request directly to the network, bypassing remaining handlers.

  Accepts `:url`, `:method`, `:headers` (map or pairs), and binary `:post_data`.
  The URL must retain its original protocol. Browser restrictions on overriding
  headers (including Cookie) still apply. Headers carry over redirects; URL,
  method and body overrides apply only to the original request.
  """
  def continue(%__MODULE__{} = route, opts \\ []), do: continue_or_fallback(route, :continue, opts)

  @doc """
  Tries the next matching handler, then the network if none remain.

  Accepts the same overrides as `continue/2`. Subsequent callbacks see the
  overrides in their request metadata, but matching uses the original URL.
  """
  def fallback(%__MODULE__{} = route, opts \\ []), do: continue_or_fallback(route, :fallback, opts)

  defp continue_or_fallback(route, action, opts) do
    opts =
      validate!(route, opts,
        url: [type: :string],
        method: [type: :string],
        headers: [type: :any],
        post_data: [type: :string]
      )

    params = opts |> Keyword.take([:url, :method, :headers, :post_data]) |> Map.new()

    params =
      if Map.has_key?(params, :headers), do: Map.update!(params, :headers, &header_array(headers(&1))), else: params

    params = if Map.has_key?(params, :post_data), do: Map.update!(params, :post_data, &Base.encode64/1), else: params
    resolve(route, action, params, opts)
  end

  defp validate!(route, opts, schema) do
    NimbleOptions.validate!(
      opts,
      schema ++ [connection: [type: :any, default: route.connection], timeout: [type: :timeout, default: route.timeout]]
    )
  end

  defp resolve(route, action, params, opts) do
    if opts[:connection] != route.connection &&
         GenServer.whereis(opts[:connection]) != GenServer.whereis(route.connection) do
      raise ArgumentError, "route belongs to another connection"
    end

    Routing.resolve(route, action, params, opts[:timeout])
  end

  defp headers(values), do: Map.new(values, fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
  defp header_array(values), do: Enum.map(values, fn {name, value} -> %{name: name, value: value} end)
end
