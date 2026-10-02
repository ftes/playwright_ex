defmodule PlaywrightEx.Routing do
  @moduledoc false
  use GenServer

  alias PlaywrightEx.Channel
  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Route
  alias PlaywrightEx.RouteMatcher

  def register(guid, matcher, callback, opts) when is_function(callback, 2) do
    regex = RouteMatcher.compile(matcher)

    opts =
      NimbleOptions.validate!(opts,
        connection: Channel.connection_opt(),
        timeout: Channel.timeout_opt(),
        times: [type: :pos_integer]
      )

    call(opts[:connection], {:register, guid, matcher, regex, callback, self(), opts})
  end

  def remove(guid, matcher, callback, opts) do
    opts = NimbleOptions.validate!(opts, connection: Channel.connection_opt(), timeout: Channel.timeout_opt())
    call(opts[:connection], {:remove, guid, matcher, callback, :default, opts[:timeout]})
  end

  def remove_all(guid, opts) do
    opts =
      NimbleOptions.validate!(opts,
        connection: Channel.connection_opt(),
        timeout: Channel.timeout_opt(),
        behavior: [type: {:in, [:default, :wait, :ignore_errors]}, default: :default]
      )

    call(opts[:connection], {:remove, guid, :all, nil, opts[:behavior], opts[:timeout]})
  end

  defp call(connection, message) do
    with {:ok, router} <- Connection.routing(connection) do
      GenServer.call(router, message, :infinity)
    end
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> {:error, %{reason: :connection_closed}}
  end

  def resolve(_route, _action, _params, 0), do: {:error, %{reason: :timeout, message: "Timeout 0ms exceeded."}}

  def resolve(route, action, params, timeout) do
    GenServer.call(route.router, {:resolve, route.token, action, params, timeout}, :infinity)
  catch
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] -> {:error, %{reason: :connection_closed}}
  end

  def start(connection), do: GenServer.start(__MODULE__, connection)

  @impl true
  def init(connection) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(connection)

    {:ok,
     %{
       connection: connection,
       monitor: monitor,
       handlers: [],
       subscriptions: MapSet.new(),
       interceptors: MapSet.new(),
       routes: %{},
       workers: %{},
       waits: []
     }}
  end

  @impl true
  def handle_call({:register, guid, matcher, regex, callback, owner, opts}, _from, state) do
    handler = %{
      id: make_ref(),
      guid: guid,
      matcher: matcher,
      regex: regex,
      callback: callback,
      owner: owner,
      times: opts[:times],
      timeout: opts[:timeout]
    }

    with :ok <- Connection.subscribe_sync(state.connection, self(), guid),
         {:ok, _} <- patterns(state, guid, [handler | state.handlers], opts[:timeout]) do
      {:reply, {:ok, %{}},
       %{
         state
         | handlers: [handler | state.handlers],
           subscriptions: MapSet.put(state.subscriptions, guid),
           interceptors: MapSet.put(state.interceptors, guid)
       }}
    else
      error ->
        if !MapSet.member?(state.subscriptions, guid), do: Connection.unsubscribe_sync(state.connection, self(), guid)
        {:reply, error, state}
    end
  end

  def handle_call({:remove, guid, matcher, callback, behavior, timeout}, from, state) do
    kept = Enum.reject(state.handlers, &selected?(&1, guid, matcher, callback))
    # Exhausted registrations can still have running callbacks.
    refs =
      state.workers |> Enum.filter(fn {_, w} -> selected?(w, guid, matcher, callback) end) |> MapSet.new(&elem(&1, 0))

    case patterns(state, guid, kept, timeout) do
      {:ok, _} ->
        workers = ignore_errors(state.workers, refs, behavior)
        state = cleanup_subscriptions(%{state | handlers: kept, workers: workers})
        removal_reply(state, from, refs, behavior)

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:resolve, token, action, params, timeout}, _from, state) do
    case Map.fetch(state.routes, token) do
      :error ->
        {:reply, {:error, %{reason: :route_already_handled}}, state}

      {:ok, route} ->
        resolve_route(state, token, route, action, params, timeout)
    end
  end

  @impl true
  def handle_info({:playwright_msg, %{guid: scope, method: :route, params: %{route: %{guid: guid}}}}, state) do
    initializer = Connection.initializer!(state.connection, guid)
    request = Map.merge(Connection.initializer!(state.connection, initializer.request.guid), initializer.request)
    scopes = Connection.routing_scopes(state.connection, scope)
    request_scopes = if request[:frame], do: Connection.routing_scopes(state.connection, request.frame.guid), else: scopes
    ids = for scope <- scopes, h <- state.handlers, h.guid == scope, Regex.match?(h.regex, request.url), do: h.id

    route = %{
      guid: guid,
      source: scope,
      request: request,
      remaining: ids,
      scopes: Enum.uniq(scopes ++ request_scopes),
      overrides: %{}
    }

    state = Enum.reduce(route.scopes, state, &subscribe_scope/2)

    {:noreply, dispatch(state, route)}
  rescue
    ArgumentError -> {:noreply, state}
  end

  def handle_info({:playwright_msg, %{guid: guid, method: method}}, state)
      when method in [:close, :crash, :__dispose__] do
    {workers, active} = Enum.split_with(state.workers, fn {_ref, w} -> guid in w.scopes end)
    Enum.each(workers, fn {_ref, w} -> Process.exit(w.pid, :kill) end)

    state = %{
      state
      | handlers: Enum.reject(state.handlers, &(&1.guid == guid)),
        routes: Map.reject(state.routes, fn {_token, r} -> guid in r.scopes end),
        workers: Map.new(active)
    }

    state = Enum.reduce(workers, state, fn {ref, _}, acc -> finish_waits(acc, ref) end)
    {:noreply, cleanup_subscriptions(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state) do
    Enum.each(state.workers, fn {_, w} -> Process.exit(w.pid, :kill) end)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, state) do
    {worker, workers} = Map.pop(state.workers, ref)
    state = %{state | workers: workers}

    state =
      cond do
        worker && reason != :normal -> failed(state, worker, reason)
        worker && worker.next -> dispatch(state, worker.next)
        true -> state
      end

    {:noreply, state |> finish_waits(ref) |> cleanup_subscriptions()}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp dispatch(state, %{remaining: []} = route) do
    _ = command(state, route.guid, :continue, Map.put(route.overrides, :is_fallback, false), :infinity)
    cleanup_subscriptions(state)
  end

  defp dispatch(state, %{remaining: [id | rest]} = route) do
    route = %{route | remaining: rest}

    case Enum.find(state.handlers, &(&1.id == id)) do
      nil ->
        dispatch(state, route)

      handler ->
        start_callback(state, route, handler)
    end
  end

  defp start_callback(state, route, handler) do
    handlers = consume(state.handlers, handler)
    token = make_ref()
    handle = %Route{router: self(), token: token, connection: state.connection, timeout: handler.timeout}
    request = Map.merge(route.request, route.overrides)
    request = if Map.has_key?(request, :post_data), do: Map.update!(request, :post_data, &Base.decode64!/1), else: request
    {pid, ref} = :erlang.spawn_opt(fn -> run_callback(handler.callback, handle, request) end, [:link, :monitor])
    worker = Map.merge(handler, %{pid: pid, token: token, scopes: route.scopes, ignore_errors: false, next: nil})

    state = %{
      state
      | handlers: handlers,
        routes: Map.put(state.routes, token, route),
        workers: Map.put(state.workers, ref, worker)
    }

    if handler.times == 1, do: patterns(state, handler.guid, handlers, :infinity)
    state
  end

  defp run_callback(callback, handle, request) do
    callback.(handle, request)
  catch
    kind, reason -> exit({:callback_failed, kind, reason, __STACKTRACE__})
  end

  defp consume(handlers, %{times: nil}), do: handlers
  defp consume(handlers, %{times: 1, id: id}), do: Enum.reject(handlers, &(&1.id == id))

  defp consume(handlers, %{times: times, id: id}),
    do: Enum.map(handlers, fn h -> if h.id == id, do: %{h | times: times - 1}, else: h end)

  defp subscribe_scope(guid, state) do
    if MapSet.member?(state.subscriptions, guid) do
      state
    else
      case Connection.subscribe_sync(state.connection, self(), guid) do
        :ok -> %{state | subscriptions: MapSet.put(state.subscriptions, guid)}
        _ -> state
      end
    end
  end

  defp selected?(handler, guid, :all, _callback), do: handler.guid == guid

  defp selected?(handler, guid, matcher, callback),
    do: handler.guid == guid && handler.matcher == matcher && (callback == nil || handler.callback == callback)

  defp ignore_errors(workers, refs, :ignore_errors) do
    Map.new(workers, fn {ref, worker} ->
      {ref, %{worker | ignore_errors: worker.ignore_errors || MapSet.member?(refs, ref)}}
    end)
  end

  defp ignore_errors(workers, _refs, _behavior), do: workers

  defp removal_reply(state, from, refs, :wait) do
    if MapSet.size(refs) > 0,
      do: {:noreply, %{state | waits: [{from, refs} | state.waits]}},
      else: {:reply, {:ok, %{}}, state}
  end

  defp removal_reply(state, _from, _refs, _behavior), do: {:reply, {:ok, %{}}, state}

  defp resolve_route(state, token, route, :fallback, params, _timeout) do
    route = %{route | overrides: Map.merge(route.overrides, params)}
    state = %{state | routes: Map.delete(state.routes, token)}
    {:reply, {:ok, %{}}, defer_fallback(state, token, route)}
  end

  defp resolve_route(state, token, route, action, params, timeout) do
    params =
      if action == :continue, do: route.overrides |> Map.merge(params) |> Map.put(:is_fallback, false), else: params

    result = command(state, route.guid, action, params, timeout)
    state = if match?({:ok, _}, result), do: %{state | routes: Map.delete(state.routes, token)}, else: state
    {:reply, result, cleanup_subscriptions(state)}
  end

  # JS awaits both the callback and its resolution before moving to the next
  # handler. fallback/2 itself returns immediately, so callbacks can finish work.
  defp defer_fallback(state, token, route) do
    case Enum.find(state.workers, fn {_, worker} -> worker.token == token end) do
      nil -> dispatch(state, route)
      {ref, worker} -> put_in(state.workers[ref], %{worker | next: route})
    end
  end

  defp failed(state, worker, reason) do
    if !worker.ignore_errors,
      do: send(worker.owner, {:playwright_route_error, %{guid: worker.guid, matcher: worker.matcher, reason: reason}})

    case {worker.next || state.routes[worker.token], Map.delete(state.routes, worker.token)} do
      {nil, _} ->
        state

      {route, routes} ->
        _ = command(state, route.guid, :abort, %{error_code: "failed"}, :infinity)
        %{state | routes: routes}
    end
  end

  defp finish_waits(state, ref) do
    waits =
      Enum.flat_map(state.waits, fn {from, refs} ->
        refs = MapSet.delete(refs, ref)

        if MapSet.size(refs) == 0 do
          GenServer.reply(from, {:ok, %{}})
          []
        else
          [{from, refs}]
        end
      end)

    %{state | waits: waits}
  end

  defp cleanup_subscriptions(state) do
    subscriptions =
      Enum.reduce(state.subscriptions, state.subscriptions, fn guid, acc ->
        used? =
          Enum.any?(state.handlers, &(&1.guid == guid)) || Enum.any?(state.routes, fn {_, r} -> guid in r.scopes end) ||
            Enum.any?(state.workers, fn {_, w} -> guid in w.scopes end)

        if used? do
          acc
        else
          disable_interceptor(state, guid)
          Connection.unsubscribe_sync(state.connection, self(), guid)
          MapSet.delete(acc, guid)
        end
      end)

    %{state | subscriptions: subscriptions, interceptors: MapSet.intersection(state.interceptors, subscriptions)}
  end

  defp disable_interceptor(state, guid) do
    if MapSet.member?(state.interceptors, guid), do: patterns(state, guid, state.handlers, :infinity)
  end

  defp patterns(state, guid, handlers, timeout) do
    # Removing the server interceptor releases its paused requests. Keep it
    # installed until existing handles resolve, even after the last registration
    # expires or is removed. New requests fall through the empty local list.
    active? =
      Enum.any?(handlers, &(&1.guid == guid)) || Enum.any?(state.routes, fn {_, route} -> route.source == guid end) ||
        Enum.any?(state.workers, fn {_, w} -> w.next && w.next.source == guid end)

    patterns = if active?, do: [%{glob: "**/*"}], else: []
    command(state, guid, :set_network_interception_patterns, %{patterns: patterns}, timeout)
  end

  defp command(state, guid, method, params, timeout) do
    state.connection
    |> Connection.send(%{guid: guid, method: method, params: params}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
