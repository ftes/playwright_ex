defmodule PlaywrightEx.Client.Response do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc "Port of `Response` in `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.RawHeaders
  alias PlaywrightEx.Client.Request

  def from(response) do
    response
  end

  def from_nullable(response) do
    if response, do: from(response)
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_finishedPromise, Promise.new(this.baton))
    put(this, :_provisionalHeaders, RawHeaders.new(initializer.headers))
    put(this, :_request, Request.from(get(this, :_initializer).request))
    put(get(this, :_request), :_response, this)
    update(get(this, :_request), :_timing, &Map.merge(&1, get(this, :_initializer).timing))
    this
  end

  def url(this) do
    get(this, :_initializer).url
  end

  def ok(this) do
    # Status 0 is for file:// URLs
    status = get(this, :_initializer).status
    status == 0 or (status >= 200 and status <= 299)
  end

  def status(this) do
    get(this, :_initializer).status
  end

  def status_text(this) do
    get(this, :_initializer).statusText
  end

  def from_service_worker(this) do
    get(this, :_initializer).fromServiceWorker
  end

  # @deprecated
  def headers(this) do
    RawHeaders.headers(get(this, :_provisionalHeaders))
  end

  def _actual_headers(this) do
    if !get(this, :_actualHeadersPromise) do
      put(
        this,
        :_actualHeadersPromise,
        Promise.async(this.baton, fn ->
          RawHeaders.new(channel_call(this, :rawResponseHeaders, %{}, TimeoutSettings.k_no_timeout()).headers)
        end)
      )
    end

    Promise.await(get(this, :_actualHeadersPromise))
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

  def header_values(this, name) do
    RawHeaders.get_all(_actual_headers(this), name)
  end

  # finished  -- not ported: LongStandingScope

  def body(this) do
    channel_call(this, :body, %{}, TimeoutSettings.k_no_timeout()).binary
  end

  def text(this) do
    body(this)
  end

  def json(this) do
    JSON.decode!(text(this))
  end

  def request(this) do
    get(this, :_request)
  end

  def frame(this) do
    Request.frame(get(this, :_request))
  end

  def server_addr(this) do
    channel_call(this, :serverAddr, %{}, TimeoutSettings.k_no_timeout())[:value] || nil
  end

  def security_details(this) do
    channel_call(this, :securityDetails, %{}, TimeoutSettings.k_no_timeout())[:value] || nil
  end

  def http_version(this) do
    channel_call(this, :httpVersion, %{}, TimeoutSettings.k_no_timeout()).value
  end
end
