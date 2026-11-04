defmodule PlaywrightEx.Client.Request do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc "Port of `Request` in `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.RawHeaders
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Isomorphic.LongStandingScope

  def from(request) do
    request
  end

  def from_nullable(request) do
    if request, do: from(request)
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_redirectedFrom, nil)
    put(this, :_redirectedTo, nil)
    put(this, :_failureText, nil)
    put(this, :_response, nil)
    put(this, :_fallbackOverrides, %{})
    put(this, :_redirectedFrom, from_nullable(initializer[:redirectedFrom]))
    if get(this, :_redirectedFrom), do: put(get(this, :_redirectedFrom), :_redirectedTo, this)
    put(this, :_provisionalHeaders, RawHeaders.new(initializer.headers))

    put(this, :_timing, %{
      startTime: 0,
      domainLookupStart: -1,
      domainLookupEnd: -1,
      connectStart: -1,
      secureConnectionStart: -1,
      connectEnd: -1,
      requestStart: -1,
      responseStart: -1,
      responseEnd: -1
    })

    this
  end

  def url(this) do
    get(this, :_fallbackOverrides)[:url] || get(this, :_initializer).url
  end

  def resource_type(this) do
    get(this, :_initializer).resourceType
  end

  def method(this) do
    get(this, :_fallbackOverrides)[:method] || get(this, :_initializer).method
  end

  def post_data(this) do
    get(this, :_fallbackOverrides)[:postDataBuffer] || get(this, :_initializer)[:postData]
  end

  def post_data_buffer(this) do
    get(this, :_fallbackOverrides)[:postDataBuffer] || get(this, :_initializer)[:postData]
  end

  def post_data_json(this) do
    post_data = post_data(this)

    if !post_data do
      nil
    else
      content_type = headers(this)["content-type"]

      if content_type && String.contains?(content_type, "application/x-www-form-urlencoded") do
        URI.decode_query(post_data)
      else
        case JSON.decode(post_data) do
          {:ok, value} -> value
          {:error, _} -> raise "POST data is not a valid JSON object: " <> post_data
        end
      end
    end
  end

  # @deprecated
  def headers(this) do
    if get(this, :_fallbackOverrides)[:headers],
      do: RawHeaders.headers(RawHeaders._from_headers_object_lossy(get(this, :_fallbackOverrides).headers)),
      else: RawHeaders.headers(get(this, :_provisionalHeaders))
  end

  def _actual_headers(this) do
    if get(this, :_fallbackOverrides)[:headers] do
      RawHeaders._from_headers_object_lossy(get(this, :_fallbackOverrides).headers)
    else
      if !get(this, :_actualHeadersPromise) do
        put(
          this,
          :_actualHeadersPromise,
          Promise.async(this.baton, fn ->
            _wrap_api_call(
              this,
              fn _ ->
                RawHeaders.new(channel_call(this, :rawRequestHeaders, %{}, TimeoutSettings.k_no_timeout()).headers)
              end,
              %{internal: true}
            )
          end)
        )
      end

      Promise.await(get(this, :_actualHeadersPromise))
    end
  end

  def all_headers(this) do
    RawHeaders.headers(_actual_headers(this))
  end

  def headers_array(this) do
    RawHeaders.headers_array(_actual_headers(this))
  end

  def header_value(this, name) do
    RawHeaders.get(_actual_headers(this), name)
  end

  def response(this) do
    Response.from_nullable(channel_call(this, :response, %{}, TimeoutSettings.k_no_timeout())[:response])
  end

  def _internal_response(this) do
    Response.from_nullable(channel_call(this, :response, %{}, TimeoutSettings.k_no_timeout())[:response])
  end

  def existing_response(this) do
    get(this, :_response)
  end

  def frame(this) do
    if !get(this, :_initializer)[:frame] do
      if !service_worker(this), do: raise("Assertion error")
      raise "Service Worker requests do not have an associated frame."
    end

    frame = Frame.from(get(this, :_initializer).frame)

    if !get(frame, :_page) do
      raise Enum.join(
              [
                "Frame for this navigation request is not available, because the request",
                "was issued before the frame is created. You can check whether the request",
                "is a navigation request by calling isNavigationRequest() method."
              ],
              "\n"
            )
    end

    frame
  end

  def _safe_page(this) do
    frame = Frame.from_nullable(get(this, :_initializer)[:frame])
    (frame && get(frame, :_page)) || nil
  end

  def service_worker(this) do
    # Worker.from(...)  -- Worker is not ported: the DummyChannelOwner
    get(this, :_initializer)[:serviceWorker]
  end

  def is_navigation_request(this) do
    get(this, :_initializer).isNavigationRequest
  end

  def redirected_from(this) do
    get(this, :_redirectedFrom)
  end

  def redirected_to(this) do
    get(this, :_redirectedTo)
  end

  def failure(this) do
    if get(this, :_failureText) == nil do
      nil
    else
      %{errorText: get(this, :_failureText)}
    end
  end

  def timing(this) do
    get(this, :_timing)
  end

  def sizes(this) do
    response = response(this)
    if !response, do: raise("Unable to fetch sizes for failed request")
    channel_call(response, :sizes, %{}, TimeoutSettings.k_no_timeout()).sizes
  end

  def _set_response_end_timing(this, response_end_timing) do
    update(this, :_timing, fn timing ->
      timing = %{timing | responseEnd: response_end_timing}
      if timing.responseStart == -1, do: %{timing | responseStart: response_end_timing}, else: timing
    end)
  end

  def _final_request(this) do
    if get(this, :_redirectedTo), do: _final_request(get(this, :_redirectedTo)), else: this
  end

  def _apply_fallback_overrides(this, overrides) do
    if overrides[:url], do: update(this, :_fallbackOverrides, &Map.put(&1, :url, overrides.url))
    if overrides[:method], do: update(this, :_fallbackOverrides, &Map.put(&1, :method, overrides.method))
    if overrides[:headers], do: update(this, :_fallbackOverrides, &Map.put(&1, :headers, overrides.headers))

    cond do
      is_binary(overrides[:postData]) ->
        update(this, :_fallbackOverrides, &Map.put(&1, :postDataBuffer, overrides.postData))

      match?({:binary, _}, overrides[:postData]) ->
        update(this, :_fallbackOverrides, &Map.put(&1, :postDataBuffer, elem(overrides.postData, 1)))

      overrides[:postData] ->
        update(this, :_fallbackOverrides, &Map.put(&1, :postDataBuffer, JSON.encode!(overrides.postData)))

      true ->
        nil
    end
  end

  def _fallback_overrides_for_continue(this) do
    get(this, :_fallbackOverrides)
  end

  def _target_closed_scope(this) do
    service_worker = service_worker(this)
    page = _safe_page(this)

    (service_worker && get(service_worker, :_closedScope)) || (page && get(page, :_closedOrCrashedScope)) ||
      LongStandingScope.new(this.baton)
  end
end
