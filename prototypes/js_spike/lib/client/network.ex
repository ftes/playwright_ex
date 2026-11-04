# upstream: packages/playwright-core/src/client/network.ts (Request/Response/Route/RouteHandler subset)
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

      put(this, :_fallbackOverrides, %{})
      this
    end

    # upstream: network.ts:141
    def url(this) do
      get(this, :_fallbackOverrides)[:url] || get(this, :_initializer).url
    end

    # upstream: network.ts:149
    def method(this) do
      get(this, :_fallbackOverrides)[:method] || get(this, :_initializer).method
    end

    # upstream: network.ts:227
    def frame(this) do
      if !get(this, :_initializer)[:frame], do: raise("Service Worker requests do not have an associated frame.")
      frame = PlaywrightJS.Client.Frame.from(get(this, :_initializer).frame)

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

    # upstream: network.ts:243
    def _safe_page(this) do
      frame = PlaywrightJS.Client.Frame.from_nullable(get(this, :_initializer)[:frame])
      (frame && get(frame, :_page)) || nil
    end

    # upstream: network.ts:219
    def _internal_response(this) do
      PlaywrightJS.Client.Network.Response.from_nullable(channel_call(this, :response, %{}, TimeoutSettings.k_no_timeout())[:response])
    end

    # upstream: network.ts:288
    def _final_request(this) do
      if get(this, :_redirectedTo), do: _final_request(get(this, :_redirectedTo)), else: this
    end

    # upstream: network.ts:292
    def _apply_fallback_overrides(this, overrides) do
      if overrides[:url], do: update(this, :_fallbackOverrides, &Map.put(&1, :url, overrides.url))
      if overrides[:method], do: update(this, :_fallbackOverrides, &Map.put(&1, :method, overrides.method))
      if overrides[:headers], do: update(this, :_fallbackOverrides, &Map.put(&1, :headers, overrides.headers))

      cond do
        is_binary(overrides[:postData]) -> update(this, :_fallbackOverrides, &Map.put(&1, :postDataBuffer, overrides.postData))
        match?({:binary, _}, overrides[:postData]) -> update(this, :_fallbackOverrides, &Map.put(&1, :postDataBuffer, elem(overrides.postData, 1)))
        overrides[:postData] -> update(this, :_fallbackOverrides, &Map.put(&1, :postDataBuffer, JSON.encode!(overrides.postData)))
        true -> nil
      end
    end

    # upstream: network.ts:308
    def _fallback_overrides_for_continue(this) do
      get(this, :_fallbackOverrides)
    end

    # upstream: network.ts:312  -- not ported: LongStandingScope (see Route._race_with_target_close)
  end

  # upstream: network.ts:317
  defmodule Route do
    use PlaywrightJS.Client.ChannelOwner
    alias PlaywrightJS.Client.Network.Request
    alias PlaywrightJS.Isomorphic.Headers

    # upstream: network.ts:322
    def from(route) do
      route
    end

    # upstream: network.ts:326
    def new(parent, type, guid, initializer) do
      this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
      put(this, :_handlingPromise, nil)
      put(this, :_didThrow, false)
      this
    end

    # upstream: network.ts:330
    def request(this) do
      Request.from(get(this, :_initializer).request)
    end

    # upstream: network.ts:334
    defp _race_with_target_close(_this, promise) do
      # When page closes or crashes, we catch any potential rejects from this Route.
      # Note that page could be missing when routing popup's initial request that
      # does not have a Page initialized just yet.
      # return await this.request()._targetClosedScope().safeRace(promise);  -- not ported: LongStandingScope
      promise.()
    end

    # upstream: network.ts:341
    def _start_handling(this) do
      put(this, :_handlingPromise, Promise.new(this.conn))
      get(this, :_handlingPromise)
    end

    # upstream: network.ts:346
    def fallback(this, options \\ %{}) do
      _check_not_handled(this)
      Request._apply_fallback_overrides(request(this), options)
      _report_handled(this, false)
      nil
    end

    # upstream: network.ts:352
    def abort(this, error_code \\ nil) do
      _handle_route(this, fn ->
        _race_with_target_close(this, fn -> channel_call(this, :abort, %{errorCode: error_code}, TimeoutSettings.k_no_timeout()) end)
      end)
    end

    # upstream: network.ts:370
    def fulfill(this, options \\ %{}) do
      _handle_route(this, fn -> _inner_fulfill(this, options) end)
    end

    # upstream: network.ts:376
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

    # upstream: network.ts:387
    defp _inner_fulfill(this, options) do
      fetch_response_uid = nil
      status_option = options[:status]
      headers_option = options[:headers]
      body = options[:body]

      body =
        if options[:json] != nil do
          if options[:body] != nil, do: raise("Can specify either body or json parameters")
          JSON.encode!(options.json)
        else
          body
        end

      # if (options.response instanceof APIResponse) ...  -- not ported: APIRequestContext

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

      headers = for {header, value} <- headers_option || %{}, into: %{}, do: {String.downcase(to_string(header)), to_string(value)}

      headers =
        cond do
          options[:contentType] -> Map.put(headers, "content-type", to_string(options.contentType))
          options[:json] -> Map.put(headers, "content-type", "application/json")
          options[:path] -> Map.put(headers, "content-type", get_mime_type_for_path(options.path) || "application/octet-stream")
          true -> headers
        end

      headers = if length != 0 and !Map.has_key?(headers, "content-length"), do: Map.put(headers, "content-length", to_string(length)), else: headers

      _race_with_target_close(this, fn ->
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
    end

    # utils/mimeType.ts getMimeTypeForPath (subset)
    defp get_mime_type_for_path(path) do
      %{".html" => "text/html", ".js" => "application/javascript", ".css" => "text/css", ".json" => "application/json", ".png" => "image/png", ".txt" => "text/plain"}[
        Path.extname(path)
      ]
    end

    # upstream: network.ts:444
    def continue(this, options \\ %{}) do
      _handle_route(this, fn ->
        Request._apply_fallback_overrides(request(this), options)
        _inner_continue(this, false)
      end)
    end

    # upstream: network.ts:451
    def _check_not_handled(this) do
      if !get(this, :_handlingPromise), do: raise("Route is already handled!")
    end

    # upstream: network.ts:456
    def _report_handled(this, done) do
      chain = get(this, :_handlingPromise)
      put(this, :_handlingPromise, nil)
      Promise.resolve(chain, done)
    end

    # upstream: network.ts:462
    def _inner_continue(this, is_fallback) do
      options = Request._fallback_overrides_for_continue(request(this))

      _race_with_target_close(this, fn ->
        channel_call(
          this,
          :continue,
          %{
            url: options[:url],
            method: options[:method],
            headers: if(options[:headers], do: Headers.headers_object_to_array(options.headers)),
            postData: if(options[:postDataBuffer], do: Base.encode64(options.postDataBuffer)),
            isFallback: is_fallback
          },
          TimeoutSettings.k_no_timeout()
        )
      end)
    end
  end

  # upstream: network.ts:845
  # Not a channel owner, but mutable (handledCount, _activeInvocations) -> heap object.
  defmodule RouteHandler do
    import PlaywrightJS.Runtime.Heap
    alias PlaywrightJS.Runtime.{Promise, Zones}
    alias PlaywrightJS.Client.{Connection, Errors, LocalUtils}
    alias PlaywrightJS.Client.Network.Route
    alias PlaywrightJS.Isomorphic.UrlMatch

    defstruct [:guid, :conn]

    # upstream: network.ts:855
    # DEVIATION: takes the connection: string globs are resolved once by the driver
    # (LocalUtils.globToRegex) and the regex is cached, as in Java's UrlMatcher.
    def new(base_url, url, handler, times \\ nil, connection) do
      this = new_object(connection.conn, __MODULE__)
      put(this, :handledCount, 0)
      put(this, :_ignoreException, false)
      put(this, :_activeInvocations, [])
      put(this, :_baseURL, base_url)
      put(this, :_times, times || 9_007_199_254_740_991)
      put(this, :url, url)
      put(this, :handler, handler)
      put(this, :_savedZone, Zones.without(:apiZone))
      # Eagerly validate string globs so that invalid patterns throw at the call site
      # (e.g. page.route()) rather than silently aborting requests later.
      if is_binary(url),
        do: put(this, :_urlRegex, Regex.compile!(LocalUtils.glob_to_regex(Connection.local_utils(connection), url, base_url)))

      this
    end

    # upstream: network.ts:867
    def prepare_interception_patterns(handlers) do
      {patterns, all} =
        Enum.reduce(handlers, {[], false}, fn handler, {patterns, all} ->
          case UrlMatch.serialize_url_match(get(handler, :url)) do
            nil -> {patterns, true}
            serialized -> {patterns ++ [serialized], all}
          end
        end)

      if all, do: [%{glob: "**/*"}], else: patterns
    end

    # upstream: network.ts:882
    def matches(this, request_url) do
      # DEVIATION: cached regex for string globs (see new/5).
      UrlMatch.url_matches(get(this, :_baseURL), request_url, get(this, :_urlRegex) || get(this, :url))
    end

    # upstream: network.ts:886
    def handle(this, route) do
      Zones.run(get(this, :_savedZone), fn -> _handle_impl(this, route) end)
    end

    # upstream: network.ts:890
    defp _handle_impl(this, route) do
      handler_invocation = %{complete: Promise.new(this.conn), route: route}
      update(this, :_activeInvocations, &(&1 ++ [handler_invocation]))

      try do
        _handle_internal(this, route)
      rescue
        e ->
          cond do
            # If the handler was stopped (without waiting for completion), we ignore all exceptions.
            get(this, :_ignoreException) ->
              false

            Errors.is_target_closed_error(e) ->
              # We are failing in the handler because the target close closed.
              # Give user a hint!
              reraise Errors.rewrite_error_message(
                        e,
                        "\"#{Exception.message(e)}\" while running route callback.\nConsider awaiting `await page.unrouteAll({ behavior: 'ignoreErrors' })`\nbefore the end of the test to ignore remaining routes in flight."
                      ),
                      __STACKTRACE__

            true ->
              reraise e, __STACKTRACE__
          end
      after
        Promise.resolve(handler_invocation.complete, nil)
        update(this, :_activeInvocations, &List.delete(&1, handler_invocation))
      end
    end

    # upstream: network.ts:911
    def stop(this, behavior) do
      # When a handler is manually unrouted or its page/context is closed we either
      # - wait for the current handler invocations to finish
      # - or do not wait, if the user opted out of it, but swallow all exceptions
      #   that happen after the unroute/close.
      if behavior == "ignoreErrors" do
        put(this, :_ignoreException, true)
      else
        promises = for activation <- get(this, :_activeInvocations), !get(activation.route, :_didThrow), do: activation.complete
        Promise.await(Promise.all(this.conn, promises))
      end

      nil
    end

    # upstream: network.ts:928
    defp _handle_internal(this, route) do
      update(this, :handledCount, &(&1 + 1))
      handled_promise = Route._start_handling(route)
      # Extract handler into a variable to avoid [RouteHandler.handler] in the stack.
      handler = get(this, :handler)

      [handled, _] =
        Promise.await(
          Promise.all(this.conn, [handled_promise, Promise.async(this.conn, fn -> handler.(route, Route.request(route)) end)])
        )

      handled
    end

    # upstream: network.ts:940
    def will_expire(this) do
      get(this, :handledCount) + 1 >= get(this, :_times)
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
