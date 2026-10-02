defmodule PlaywrightEx.Route do
  @moduledoc """
  Resolve a request intercepted by `PlaywrightEx.Page.route/4` or
  `PlaywrightEx.BrowserContext.route/4`.

  Handles carry their connection and registration timeout. Operations return
  `{:ok, result}` or `{:error, reason}` and accept `:connection` and `:timeout`
  overrides. Each callback must resolve its handle once, before returning.
  Handles can only be used inside their callback process; returning without
  resolution is a callback failure.
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  @compile {:no_warn_undefined, MIME}

  @opaque t :: %__MODULE__{guid: PlaywrightEx.guid(), owner: pid(), connection: GenServer.server(), timeout: timeout()}
  defstruct [:guid, :owner, :connection, :timeout]

  @doc """
  Serves a response without contacting the network.

  Options: `:status` (default 200), `:headers` (map or list of name/value pairs),
  `:content_type`, and `:body` (binary, default empty). Binary bodies are encoded
  internally, including non-UTF-8 data. Header names are case insensitive; pair lists preserve duplicate names
  (for example, multiple `Set-Cookie` headers).
  Alternatively, supply `:json` (encoded with `JSON.encode!/1`, including `nil`
  and `false`) or `:path` (read from this Elixir host, including with remote
  browsers). These three body sources are mutually exclusive. JSON defaults to
  `application/json`. Files infer content type from their extension when the
  optional `:mime` dependency is installed; otherwise they use
  `application/octet-stream` (also the fallback for unknown extensions). Add
  `{:mime, "~> 2.0"}` to your dependencies to enable inference. Explicit
  Content-Type headers take precedence over defaults; `:content_type` overrides
  both.
  An unreadable file raises `File.Error`; unsupported JSON values raise an
  encoding error. Neither consumes the route handle.

  `:response` is deferred. Protocol-only options such as `:is_base64` are not
  accepted.

  ## Examples

  Choose one response per callback. These examples assume `route` is the handle
  received by the callback; its registration supplies connection and timeout.

  JSON (also supports `json: nil` and `json: false`):

      {:ok, _} = PlaywrightEx.Route.fulfill(route,
        status: 201, json: %{id: 123, name: "Ada"})

  A local JavaScript fixture, with content type inferred from `.js`:

      {:ok, _} = PlaywrightEx.Route.fulfill(route,
        path: "test/fixtures/formstack_stub.js")

  An explicit binary response:

      {:ok, _} = PlaywrightEx.Route.fulfill(route,
        content_type: "text/plain; charset=utf-8",
        headers: %{"x-test-response" => "stub"},
        body: "Hello from the test")
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

    {body, default_type} = build_fulfillment_body(opts)
    headers = normalize_headers(Keyword.fetch!(opts, :headers))
    content_type = opts[:content_type] || (!List.keymember?(headers, "content-type", 0) && default_type)

    headers =
      if content_type,
        do: [{"content-type", content_type} | Enum.reject(headers, fn {name, _} -> name == "content-type" end)],
        else: headers

    headers =
      if byte_size(body) > 0 && !List.keymember?(headers, "content-length", 0),
        do: [{"content-length", to_string(byte_size(body))} | headers],
        else: headers

    resolve(
      route,
      :fulfill,
      %{status: opts[:status], headers: serialize_headers(headers), body: Base.encode64(body), is_base64: true},
      opts
    )
  end

  defp build_fulfillment_body(opts) do
    case Keyword.take(opts, [:body, :json, :path]) do
      [] -> {"", nil}
      [body: body] -> {body, nil}
      [json: value] -> {JSON.encode!(value), "application/json"}
      [path: path] -> {File.read!(path), infer_content_type(path)}
      _ -> raise ArgumentError, "specify only one of :body, :json, or :path"
    end
  end

  defp infer_content_type(path) do
    if Code.ensure_loaded?(MIME), do: MIME.from_path(path), else: "application/octet-stream"
  end

  @doc """
  Aborts the request. `:error_code` defaults to `"failed"` (Playwright network
  error code). Call inside the registered callback:

      {:ok, _} = PlaywrightEx.Route.abort(route, error_code: "connectionfailed")
  """
  def abort(%__MODULE__{} = route, opts \\ []) do
    opts = validate!(route, opts, error_code: [type: :string, default: "failed"])
    resolve(route, :abort, %{error_code: opts[:error_code]}, opts)
  end

  @doc """
  Sends the request directly to the network. A matching page handler bypasses
  context routing when it continues a request.

  Accepts `:url`, `:method`, `:headers` (map or pairs), and binary `:post_data`.
  The URL must retain its original protocol. Browser restrictions on overriding
  headers (including Cookie) still apply. Headers carry over redirects; URL,
  method and body overrides apply only to the original request.

  ## Examples

  Forward the request unchanged from inside its callback:

      {:ok, _} = PlaywrightEx.Route.continue(route)

  To add a header, preserve the existing headers. Callback request metadata uses
  a list of `%{name: name, value: value}` entries; this operation accepts a map:

      headers = Map.new(request.headers, fn header ->
        {String.downcase(header.name), header.value}
      end)
      {:ok, _} = PlaywrightEx.Route.continue(route,
        headers: Map.put(headers, "x-test-run", "true"))
  """
  def continue(%__MODULE__{} = route, opts \\ []) do
    opts =
      validate!(route, opts,
        url: [type: :string],
        method: [type: :string],
        headers: [type: :any],
        post_data: [type: :string]
      )

    params = opts |> Keyword.take([:url, :method, :headers, :post_data]) |> Map.new()

    params =
      if Map.has_key?(params, :headers),
        do: Map.update!(params, :headers, &serialize_headers(normalize_headers(&1))),
        else: params

    params = if Map.has_key?(params, :post_data), do: Map.update!(params, :post_data, &Base.encode64/1), else: params
    resolve(route, :continue, Map.put(params, :is_fallback, false), opts)
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

    cond do
      route.owner != self() ->
        {:error, %{reason: :route_callback_only}}

      Process.get({__MODULE__, route.guid}) != false ->
        {:error, %{reason: :route_already_handled}}

      true ->
        result =
          opts[:connection]
          |> Connection.send(%{guid: route.guid, method: action, params: params}, opts[:timeout])
          |> ChannelResponse.unwrap(& &1)

        if match?({:ok, _}, result), do: Process.put({__MODULE__, route.guid}, true)
        result
    end
  end

  defp normalize_headers(values),
    do: Enum.map(values, fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)

  defp serialize_headers(values), do: Enum.map(values, fn {name, value} -> %{name: name, value: value} end)
end
