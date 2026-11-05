defmodule PlaywrightEx.Client.RouteHandler do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `RouteHandler` in `#{@upstream}`: a runtime object (mutable, in the loop's heap).

  Deviations: the constructor takes the `LocalUtils` first, as string globs become regexes
  through the driver (`PlaywrightEx.Isomorphic.UrlMatch`). The handler is a 2-arity function
  `(route, request)` or, as in the Python client, a 1-arity one `(route)`.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Route
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Runtime.Promise
  alias PlaywrightEx.Runtime.Zones

  defstruct [:guid, :loop, :heap]

  # Number.MAX_SAFE_INTEGER
  @max_safe_integer 9_007_199_254_740_991

  def new(local_utils, base_url, url, handler, times \\ nil) do
    this = new_object(__MODULE__)
    put(this, :handledCount, 0)
    put(this, :_ignoreException, false)
    put(this, :_activeInvocations, [])
    put(this, :_localUtils, local_utils)
    put(this, :_baseURL, base_url)
    put(this, :_times, if(times == nil, do: @max_safe_integer, else: times))
    put(this, :url, url)
    put(this, :handler, handler)
    # The public API name is a zone here too (`Runtime.Api`): the handler's calls have their own.
    put(this, :_savedZone, Map.delete(Zones.without(:apiZone), :apiName))
    # Eagerly validate string globs so that invalid patterns throw at the call site
    # (e.g. page.route()) rather than silently aborting requests later.
    if is_binary(url), do: UrlMatch.resolve_glob_to_regex_pattern(local_utils, base_url, url)
    this
  end

  def prepare_interception_patterns(handlers) do
    {patterns, all} =
      Enum.reduce(handlers, {[], false}, fn handler, {patterns, all} ->
        serialized = UrlMatch.serialize_url_match(get(handler, :url))
        if serialized, do: {patterns ++ [serialized], all}, else: {patterns, true}
      end)

    if all, do: [%{glob: "**/*"}], else: patterns
  end

  def matches(this, request_url) do
    # The LocalUtils comes first: globs become regexes through the driver (UrlMatch).
    UrlMatch.url_matches(get(this, :_localUtils), get(this, :_baseURL), request_url, get(this, :url))
  end

  def handle(this, route) do
    Zones.run(get(this, :_savedZone), fn -> _handle_impl(this, route) end)
  end

  defp _handle_impl(this, route) do
    handler_invocation = %{complete: Promise.new(), route: route}
    set_add(this, :_activeInvocations, handler_invocation)

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
                      ~s("#{Exception.message(e)}" while running route callback.\n) <>
                        "Consider awaiting `await page.unrouteAll({ behavior: 'ignoreErrors' })`\n" <>
                        "before the end of the test to ignore remaining routes in flight."
                    ),
                    __STACKTRACE__

          true ->
            reraise e, __STACKTRACE__
        end
    after
      Promise.resolve(handler_invocation.complete, nil)
      set_delete(this, :_activeInvocations, handler_invocation)
    end
  end

  def stop(this, behavior) do
    # When a handler is manually unrouted or its page/context is closed we either
    # - wait for the current handler invocations to finish
    # - or do not wait, if the user opted out of it, but swallow all exceptions
    #   that happen after the unroute/close.
    if behavior == "ignoreErrors" do
      put(this, :_ignoreException, true)
    else
      promises =
        for activation <- get(this, :_activeInvocations), !get(activation.route, :_didThrow), do: activation.complete

      Promise.await(Promise.all(promises))
    end

    nil
  end

  defp _handle_internal(this, route) do
    update(this, :handledCount, &(&1 + 1))
    handled_promise = Promise.async(fn -> Route._start_handling(route) end)
    # Extract handler into a variable to avoid [RouteHandler.handler] in the stack.
    handler = get(this, :handler)

    [handled, _] =
      Promise.await(
        Promise.all([
          handled_promise,
          Promise.async(fn ->
            # A 1-arity handler gets only the route (as in the Python client); JS passes both.
            if is_function(handler, 1), do: handler.(route), else: handler.(route, Route.request(route))
          end)
        ])
      )

    handled
  end

  def will_expire(this) do
    get(this, :handledCount) + 1 >= get(this, :_times)
  end
end
