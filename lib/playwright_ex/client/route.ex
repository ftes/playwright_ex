defmodule PlaywrightEx.Client.Route do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `Route` in `#{@upstream}`.

  A `body` is a string, or `{:binary, bytes}` for a JS `Buffer` (PLAN, Decisions).
  """
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.APIRequestContext
  alias PlaywrightEx.Client.APIResponse
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Isomorphic.Headers
  alias PlaywrightEx.Isomorphic.LongStandingScope
  alias PlaywrightEx.Isomorphic.MimeType

  def from(route) do
    route
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_handlingPromise, nil)
    put(this, :_didThrow, false)
    this
  end

  def request(this) do
    Request.from(get(this, :_initializer).request)
  end

  defp _race_with_target_close(this, promise) do
    # When page closes or crashes, we catch any potential rejects from this Route.
    # Note that page could be missing when routing popup's initial request that
    # does not have a Page initialized just yet.
    LongStandingScope.safe_race(Request._target_closed_scope(request(this)), promise)
  end

  def _start_handling(this) do
    put(this, :_handlingPromise, Promise.new())
    Promise.await(get(this, :_handlingPromise))
  end

  def fallback(this, options \\ %{}) do
    options = options || %{}
    _check_not_handled(this)
    Request._apply_fallback_overrides(request(this), options)
    _report_handled(this, false)
    nil
  end

  def abort(this, error_code \\ nil) do
    _handle_route(this, fn ->
      _race_with_target_close(
        this,
        Promise.async(fn -> channel_call(this, :abort, %{errorCode: error_code}, TimeoutSettings.k_no_timeout()) end)
      )
    end)
  end

  def _redirect_navigation_request(this, url) do
    _handle_route(this, fn ->
      _race_with_target_close(
        this,
        Promise.async(fn ->
          channel_call(this, :redirectNavigationRequest, %{url: url}, TimeoutSettings.k_no_timeout())
        end)
      )
    end)
  end

  def fetch(this, options \\ %{}) do
    options = options || %{}

    _wrap_api_call(this, fn _ ->
      APIRequestContext._inner_fetch(
        get(get(this, :_context), :request),
        Map.merge(%{request: request(this), data: options[:postData]}, options)
      )
    end)
  end

  def fulfill(this, options \\ %{}) do
    options = options || %{}
    _handle_route(this, fn -> _inner_fulfill(this, options) end)
  end

  defp _handle_route(this, callback) do
    _check_not_handled(this)

    try do
      callback.()
      _report_handled(this, true)
      nil
    rescue
      e ->
        put(this, :_didThrow, true)
        reraise e, __STACKTRACE__
    end
  end

  defp _inner_fulfill(this, options) do
    fetch_response_uid = nil

    %{status: status_option, headers: headers_option, body: body} =
      Map.merge(%{status: nil, headers: nil, body: nil}, options)

    body =
      if options[:json] != nil do
        if options[:body] != nil, do: raise("Can specify either body or json parameters")
        ClientHelper.json_stringify(options.json)
      else
        body
      end

    {status_option, headers_option, body, fetch_response_uid} =
      case options[:response] do
        %APIResponse{} = response ->
          status_option = if status_option == nil, do: APIResponse.status(response), else: status_option
          headers_option = if headers_option == nil, do: APIResponse.headers(response), else: headers_option

          cond do
            body != nil or options[:path] != nil ->
              {status_option, headers_option, body, fetch_response_uid}

            get(response._request, :_connection) == get(this, :_connection) ->
              {status_option, headers_option, body, APIResponse._fetch_uid(response)}

            true ->
              {status_option, headers_option, {:binary, APIResponse.body(response)}, fetch_response_uid}
          end

        _ ->
          {status_option, headers_option, body, fetch_response_uid}
      end

    {body, is_base64, length} =
      cond do
        options[:path] ->
          buffer = File.read!(options.path)
          {Base.encode64(buffer), true, byte_size(buffer)}

        is_binary(body) ->
          {body, false, byte_size(body)}

        match?({:binary, _}, body) ->
          {:binary, buffer} = body
          {Base.encode64(buffer), true, byte_size(buffer)}

        true ->
          {body, false, 0}
      end

    headers =
      for {header, value} <- headers_option || %{},
          into: %{},
          do:
            {String.downcase(to_string(header)),
             if(is_number(value), do: ClientHelper.number_to_string(value), else: to_string(value))}

    headers =
      cond do
        ClientHelper.truthy(options[:contentType]) ->
          Map.put(headers, "content-type", to_string(options.contentType))

        ClientHelper.truthy(options[:json]) ->
          Map.put(headers, "content-type", "application/json")

        ClientHelper.truthy(options[:path]) ->
          Map.put(headers, "content-type", MimeType.get_mime_type_for_path(options.path) || "application/octet-stream")

        true ->
          headers
      end

    headers =
      if length != 0 and !Map.has_key?(headers, "content-length"),
        do: Map.put(headers, "content-length", to_string(length)),
        else: headers

    _race_with_target_close(
      this,
      Promise.async(fn ->
        channel_call(
          this,
          :fulfill,
          %{
            status: status_option || 200,
            headers: Headers.headers_object_to_array(headers),
            body: body,
            isBase64: is_base64,
            fetchResponseUid: fetch_response_uid
          },
          TimeoutSettings.k_no_timeout()
        )
      end)
    )
  end

  def continue(this, options \\ %{}) do
    options = options || %{}

    _handle_route(this, fn ->
      Request._apply_fallback_overrides(request(this), options)
      _inner_continue(this, false)
    end)
  end

  def _check_not_handled(this) do
    if !get(this, :_handlingPromise), do: raise("Route is already handled!")
  end

  def _report_handled(this, done) do
    chain = get(this, :_handlingPromise)
    put(this, :_handlingPromise, nil)
    Promise.resolve(chain, done)
  end

  def _inner_continue(this, is_fallback) do
    options = Request._fallback_overrides_for_continue(request(this))

    _race_with_target_close(
      this,
      Promise.async(fn ->
        channel_call(
          this,
          :continue,
          %{
            url: options[:url],
            method: options[:method],
            headers: if(options[:headers], do: Headers.headers_object_to_array(options.headers)),
            postData: options[:postDataBuffer],
            isFallback: is_fallback
          },
          TimeoutSettings.k_no_timeout()
        )
      end)
    )
  end
end
