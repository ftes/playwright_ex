# upstream: packages/playwright-core/src/client/network.ts (Request/Response subset)
defmodule PlaywrightJS.Client.Network do
  # upstream: network.ts:104
  defmodule Request do
    use PlaywrightJS.Client.ChannelOwner

    # upstream: network.ts:114
    def from(request) do
      request
    end

    # upstream: network.ts:118
    def from_nullable(request) do
      if request, do: from(request), else: nil
    end

    # upstream: network.ts:122
    def new(parent, type, guid, initializer) do
      this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
      put(this, :_redirectedFrom, from_nullable(initializer[:redirectedFrom]))
      if get(this, :_redirectedFrom), do: put(get(this, :_redirectedFrom), :_redirectedTo, this)
      # this._provisionalHeaders = new RawHeaders(initializer.headers);  -- not ported
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

    # upstream: network.ts:219
    def _internal_response(this) do
      PlaywrightJS.Client.Network.Response.from_nullable(channel_call(this, :response, %{}, TimeoutSettings.k_no_timeout())[:response])
    end

    # upstream: network.ts:288
    def _final_request(this) do
      if get(this, :_redirectedTo), do: _final_request(get(this, :_redirectedTo)), else: this
    end
  end

  # upstream: network.ts:666
  defmodule Response do
    use PlaywrightJS.Client.ChannelOwner

    # upstream: network.ts:672
    def from(response) do
      response
    end

    # upstream: network.ts:676
    def from_nullable(response) do
      if response, do: from(response), else: nil
    end

    # upstream: network.ts:680
    def new(parent, type, guid, initializer) do
      this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
      # this._provisionalHeaders = new RawHeaders(initializer.headers);  -- not ported
      put(this, :_request, Request.from(get(this, :_initializer).request))
      put(get(this, :_request), :_response, this)
      update(get(this, :_request), :_timing, &Map.merge(&1, get(this, :_initializer).timing))
      this
    end

    # upstream: network.ts:688
    def url(this) do
      get(this, :_initializer).url
    end

    # upstream: network.ts:692
    def ok(this) do
      # Status 0 is for file:// URLs
      get(this, :_initializer).status == 0 or (get(this, :_initializer).status >= 200 and get(this, :_initializer).status <= 299)
    end

    # upstream: network.ts:697
    def status(this) do
      get(this, :_initializer).status
    end
  end
end
