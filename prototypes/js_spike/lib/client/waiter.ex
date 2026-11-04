# upstream: packages/playwright-core/src/client/waiter.ts
defmodule PlaywrightJS.Client.Waiter do
  import PlaywrightJS.Runtime.Heap
  alias PlaywrightJS.Runtime.{Baton, Promise}
  alias PlaywrightJS.Client.{ChannelOwner, Connection, Errors}

  defstruct [:guid, :conn]

  # upstream: waiter.ts:37
  def new(channel_owner, event) do
    this = new_object(channel_owner.conn, __MODULE__)
    put(this, :_failures, [])
    put(this, :_logs, [])
    put(this, :_waitId, create_guid())
    put(this, :_channelOwner, channel_owner)
    # this._savedZone = currentZone().without('apiZone');  -- n/a: listeners are handed off from dispatch, which runs outside any zone

    title = "Wait for event \"#{event}\""
    _send_wait_info(this, %{waitId: get(this, :_waitId), phase: "before", event: event}, %{title: title})

    put(this, :_dispose, [
      fn -> _send_wait_info(this, %{waitId: get(this, :_waitId), phase: "after", error: get(this, :_error)}, %{internal: true}) end
    ])

    this
  end

  # upstream: waiter.ts:49
  def create_for_event(channel_owner, event) do
    new(channel_owner, event)
  end

  # upstream: waiter.ts:53
  defp _send_wait_info(this, info, options) do
    # Fire-and-forget: server intentionally never replies, and we never throw to the caller.
    owner = get(this, :_channelOwner)

    try do
      ChannelOwner._wrap_api_call(
        owner,
        fn api_zone ->
          if api_zone.internal or api_zone.reported do
            Connection.send_message_to_server(get(owner, :_connection), owner, "__waitInfo__", info, %{internal: true, timeout: 0})
          else
            api_zone = PlaywrightJS.Runtime.Zones.update(:apiZone, &%{&1 | reported: true})
            # An outer `_wrapApiCall` may have set its own title (e.g. "Wait for navigation");
            # fall back to ours only when the outer zone left it blank.
            api_zone = if !api_zone.title, do: PlaywrightJS.Runtime.Zones.update(:apiZone, &%{&1 | title: options[:title]}), else: api_zone
            # owner._instrumentation.onApiCallBegin(...)  -- not ported
            Connection.send_message_to_server(get(owner, :_connection), owner, "__waitInfo__", info, Map.put(api_zone, :timeout, 0))
          end
        end,
        options
      )
    rescue
      _ -> nil
    end
  end

  # upstream: waiter.ts:73
  def wait_for_event(this, emitter, event, predicate \\ nil) do
    {promise, dispose} = wait_for_event_(emitter, event, nil, predicate)
    wait_for_promise(this, promise, dispose)
  end

  # upstream: waiter.ts:78
  def reject_on_event(this, emitter, event, error, predicate \\ nil) do
    {promise, dispose} = wait_for_event_(emitter, event, nil, predicate)
    _reject_on(this, Promise.then_(promise, fn _ -> raise(if is_function(error), do: error.(), else: error) end), dispose)
  end

  # upstream: waiter.ts:83
  def reject_on_timeout(this, %{timeout: timeout}, timeout_message) do
    # if (signal) { ... }  -- not ported: AbortSignal

    if timeout != 0 do
      {promise, dispose} = wait_for_timeout(this.conn, timeout)
      _reject_on(this, Promise.then_(promise, fn _ -> raise Errors.TimeoutError, message: timeout_message end), dispose)
    end
  end

  # upstream: waiter.ts:100
  def reject_immediately(this, error) do
    put(this, :_immediateError, error)
  end

  # upstream: waiter.ts:104
  def throw_if_immediately_rejected(this) do
    if get(this, :_immediateError), do: raise(get(this, :_immediateError))
  end

  # upstream: waiter.ts:109
  def dispose(this) do
    for dispose <- get(this, :_dispose), do: dispose.()
  end

  # upstream: waiter.ts:114
  def wait_for_promise(this, promise, dispose \\ nil) do
    try do
      if get(this, :_immediateError), do: raise(get(this, :_immediateError))
      result = Promise.await(Promise.race(this.conn, [promise | get(this, :_failures)]))
      if dispose, do: dispose.()
      result
    rescue
      e ->
        if dispose, do: dispose.()
        put(this, :_error, Exception.message(e))
        dispose(this)
        e = Errors.rewrite_error_message(e, Exception.message(e) <> format_log_recording(get(this, :_logs)))
        reraise e, __STACKTRACE__
    end
  end

  # upstream: waiter.ts:132
  def log(this, s) do
    update(this, :_logs, &(&1 ++ [s]))
    _send_wait_info(this, %{waitId: get(this, :_waitId), phase: "log", message: s}, %{internal: true})
  end

  # upstream: waiter.ts:137
  defp _reject_on(this, promise, dispose) do
    update(this, :_failures, &(&1 ++ [promise]))
    if dispose, do: update(this, :_dispose, &(&1 ++ [dispose]))
  end

  # upstream: waiter.ts:144
  defp wait_for_event_(emitter, event, _saved_zone, predicate) do
    # `let listener` assigned inside the executor and referenced by itself -> identify it by ref.
    listener = make_ref()

    promise =
      Promise.new(emitter.conn, fn resolve, reject ->
        listener_fun = fn event_arg ->
          try do
            if predicate && !predicate.(event_arg) do
              nil
            else
              emitter.__struct__.remove_listener(emitter, event, listener)
              resolve.(event_arg)
            end
          rescue
            e ->
              emitter.__struct__.remove_listener(emitter, event, listener)
              reject.(e)
          end
        end

        emitter.__struct__.add_listener(emitter, event, {listener, listener_fun})
      end)

    dispose = fn -> emitter.__struct__.remove_listener(emitter, event, listener) end
    {promise, dispose}
  end

  # upstream: waiter.ts:166
  defp wait_for_timeout(loop, timeout) do
    # `new Promise(resolve => timeoutId = setTimeout(resolve, timeout))`: closures cannot assign outer variables.
    promise = Promise.new(loop)
    timeout_id = Baton.set_timeout(loop, fn -> Promise.resolve(promise, nil) end, timeout)
    dispose = fn -> Baton.clear_timeout(timeout_id) end
    {promise, dispose}
  end

  # upstream: waiter.ts:173
  defp format_log_recording(log) do
    if log == [] do
      ""
    else
      header = " logs "
      header_length = 60
      left_length = div(header_length - String.length(header), 2)
      right_length = header_length - String.length(header) - left_length

      "\n#{String.duplicate("=", left_length)}#{header}#{String.duplicate("=", right_length)}\n#{Enum.join(log, "\n")}\n#{String.duplicate("=", header_length)}"
    end
  end

  # utils/crypto.ts createGuid()
  defp create_guid, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
end
