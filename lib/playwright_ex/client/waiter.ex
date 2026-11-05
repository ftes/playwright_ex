defmodule PlaywrightEx.Client.Waiter do
  @upstream "packages/playwright-core/src/client/waiter.ts"
  @moduledoc "Port of `#{@upstream}`."
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.AbortSignal
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Promise
  alias PlaywrightEx.Runtime.Zones

  defstruct [:guid, :loop, :heap]

  def new(channel_owner, event) do
    this = new_object(__MODULE__)
    put(this, :_failures, [])
    put(this, :_logs, [])
    put(this, :_waitId, create_guid())
    put(this, :_channelOwner, channel_owner)

    # this._savedZone = currentZone().without('apiZone');  -- n/a: listeners are handed off from dispatch, which runs outside any zone

    title = "Wait for event \"#{event}\""
    _send_wait_info(this, %{waitId: get(this, :_waitId), phase: "before", event: event}, %{title: title})

    put(this, :_dispose, [
      fn ->
        _send_wait_info(this, %{waitId: get(this, :_waitId), phase: "after", error: get(this, :_error)}, %{
          internal: true
        })
      end
    ])

    this
  end

  def create_for_event(channel_owner, event) do
    new(channel_owner, event)
  end

  defp _send_wait_info(this, info, options) do
    # Fire-and-forget: server intentionally never replies, and we never throw to the caller.
    owner = get(this, :_channelOwner)

    try do
      ChannelOwner._wrap_api_call(
        owner,
        fn api_zone ->
          if api_zone.internal or api_zone.reported do
            Connection.send_message_to_server(get(owner, :_connection), owner, "__waitInfo__", info, %{
              internal: true,
              timeout: 0
            })
          else
            api_zone = Zones.update(:apiZone, &%{&1 | reported: true})
            # An outer `_wrapApiCall` may have set its own title (e.g. "Wait for navigation");
            # fall back to ours only when the outer zone left it blank.
            api_zone = if !api_zone.title, do: Zones.update(:apiZone, &%{&1 | title: options[:title]}), else: api_zone
            # owner._instrumentation.onApiCallBegin(...)  -- not ported
            Connection.send_message_to_server(
              get(owner, :_connection),
              owner,
              "__waitInfo__",
              info,
              Map.put(api_zone, :timeout, 0)
            )
          end
        end,
        options
      )
    rescue
      _ -> nil
    end
  end

  def wait_for_event(this, emitter, event, predicate \\ nil) do
    {promise, dispose} = wait_for_event_(emitter, event, nil, predicate)
    wait_for_promise(this, promise, dispose)
  end

  def reject_on_event(this, emitter, event, error, predicate \\ nil) do
    {promise, dispose} = wait_for_event_(emitter, event, nil, predicate)

    _reject_on(
      this,
      Promise.then_(promise, fn _ -> raise(if is_function(error), do: error.(), else: error) end),
      dispose
    )
  end

  def reject_on_timeout(this, %{timeout: timeout} = options, timeout_message) do
    signal = options[:signal]

    if signal && AbortSignal.aborted(signal) do
      reject_immediately(this, %Errors.AbortError{cause: AbortSignal.reason(signal)})
    else
      if signal do
        # `let rejectPromise` assigned inside the executor: the promise is settled from outside.
        promise = Promise.new()
        listener = fn -> Promise.reject(promise, %Errors.AbortError{cause: AbortSignal.reason(signal)}) end
        AbortSignal.add_event_listener(signal, "abort", listener, %{once: true})
        _reject_on(this, promise, fn -> AbortSignal.remove_event_listener(signal, "abort", listener) end)
      end

      if timeout != 0 do
        {promise, dispose} = wait_for_timeout(timeout)

        _reject_on(
          this,
          Promise.then_(promise, fn _ -> raise Errors.TimeoutError, message: timeout_message end),
          dispose
        )
      end
    end
  end

  def reject_immediately(this, error) do
    put(this, :_immediateError, error)
  end

  def throw_if_immediately_rejected(this) do
    if get(this, :_immediateError), do: raise(get(this, :_immediateError))
  end

  def dispose(this) do
    for dispose <- get(this, :_dispose), do: dispose.()
  end

  def wait_for_promise(this, promise, dispose \\ nil) do
    try do
      if get(this, :_immediateError), do: raise(get(this, :_immediateError))
      result = Promise.await(Promise.race([promise | get(this, :_failures)]))
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

  def log(this, s) do
    update(this, :_logs, &(&1 ++ [s]))
    _send_wait_info(this, %{waitId: get(this, :_waitId), phase: "log", message: s}, %{internal: true})
  end

  defp _reject_on(this, promise, dispose) do
    update(this, :_failures, &(&1 ++ [promise]))
    if dispose, do: update(this, :_dispose, &(&1 ++ [dispose]))
  end

  defp wait_for_event_(emitter, event, _saved_zone, predicate) do
    # `let listener` assigned inside the executor and referenced by itself -> identify it by ref.
    listener = make_ref()

    promise =
      Promise.new(fn resolve, reject ->
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

  defp wait_for_timeout(timeout) do
    # `new Promise(resolve => timeoutId = setTimeout(resolve, timeout))`: closures cannot assign outer variables.
    promise = Promise.new()
    timeout_id = EventLoop.set_timeout(fn -> Promise.resolve(promise, nil) end, timeout)
    dispose = fn -> EventLoop.clear_timeout(timeout_id) end
    {promise, dispose}
  end

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
