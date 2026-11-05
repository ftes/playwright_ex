defmodule PlaywrightEx.Client.Waiter do
  @upstream "packages/playwright-core/src/client/waiter.ts"
  @moduledoc """
  Port of `#{@upstream}`. A Waiter lives in the process that waits (as a JS waiter lives in one
  async chain): a process-local object (`PlaywrightEx.Runtime.Heap.new_object/1`), freed by
  `dispose/1`. Its `_failures` are local promises (mailbox subscriptions, a timer, the abort
  signal), so `Promise.race` is a selective receive over them.
  """
  import PlaywrightEx.Runtime.Heap

  alias PlaywrightEx.AbortError
  alias PlaywrightEx.AbortSignal
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.ClientInstrumentation
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Runtime.Promise
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.TimeoutError

  defstruct [:guid, :conn, :table]

  def new(channel_owner, event) do
    this = new_object(__MODULE__)
    put(this, :_failures, [])
    put(this, :_logs, [])
    put(this, :_waitId, ClientHelper.create_guid())
    put(this, :_channelOwner, channel_owner)

    # Elixir: also without `apiName` (`PlaywrightEx.Runtime.Api`), as a predicate's API calls are
    # its own (JS derives the name from the stack).
    put(this, :_savedZone, Map.drop(Zones.current_zone(), [:apiZone, :apiName]))

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
          if api_zone.internal or !ChannelOwner._report(api_zone) do
            Connection.send_message_to_server(get(owner, :_connection), owner, "__waitInfo__", info, %{
              internal: true,
              timeout: 0
            })
          else
            api_zone = Zones.update(:apiZone, &%{&1 | reported: true})
            # An outer `_wrapApiCall` may have set its own title (e.g. "Wait for navigation");
            # fall back to ours only when the outer zone left it blank.
            api_zone = if !api_zone.title, do: Zones.update(:apiZone, &%{&1 | title: options[:title]}), else: api_zone

            ClientInstrumentation.on_api_call_begin(get(owner, :_instrumentation), api_zone, %{
              type: get(owner, :_type),
              method: "__waitInfo__",
              params: info
            })

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
    {promise, dispose} = wait_for_event_(emitter, event, get(this, :_savedZone), predicate)
    wait_for_promise(this, promise, dispose)
  end

  def reject_on_event(this, emitter, event, error, predicate \\ nil) do
    {promise, dispose} = wait_for_event_(emitter, event, get(this, :_savedZone), predicate)

    _reject_on(
      this,
      Promise.then_(promise, fn _ -> raise(if is_function(error), do: error.(), else: error) end),
      dispose
    )
  end

  def reject_on_timeout(this, options, timeout_message) do
    timeout = options[:timeout]
    signal = options[:signal]

    if signal && AbortSignal.aborted(signal) do
      reject_immediately(this, %AbortError{cause: AbortSignal.reason(signal)})
    else
      if signal do
        # `let rejectPromise` assigned inside the executor: the promise is settled from outside.
        # (The listener runs in the aborting process: it only sends to this one.)
        promise = Promise.new()
        listener = fn -> Promise.reject(promise, %AbortError{cause: AbortSignal.reason(signal)}) end
        AbortSignal.add_event_listener_after_check(signal, listener)

        _reject_on(this, promise, fn ->
          AbortSignal.remove_event_listener(signal, "abort", listener)
          Promise.flush(promise.ref)
        end)
      end

      # `if (timeout)`
      if timeout not in [nil, 0] do
        {promise, dispose} = wait_for_timeout(timeout)

        _reject_on(
          this,
          Promise.then_(promise, fn _ -> raise TimeoutError, message: timeout_message end),
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
    for dispose <- get(this, :_dispose) || [], do: dispose.()
    # Elixir only: the waiter's fields are erased (and late messages of its failures flushed).
    for promise <- get(this, :_failures) || [], do: Promise.flush(promise.ref)
    free(this)
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
        logs = get(this, :_logs)
        dispose(this)
        e = Errors.rewrite_error_message(e, Exception.message(e) <> format_log_recording(logs))
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

  # The listener is a mailbox subscription of this process; its predicate runs here when the
  # event message is received (JS: in emit). removeListener is the promise's cancel.
  defp wait_for_event_(emitter, event, saved_zone, predicate) do
    predicate = if predicate, do: fn arg -> Zones.run(saved_zone, fn -> predicate.(arg) end) end
    promise = impl(emitter).subscribe(emitter, event, predicate)
    {promise, promise.cancel}
  end

  defp wait_for_timeout(timeout) do
    # `new Promise(resolve => timeoutId = setTimeout(resolve, timeout))`: closures cannot assign outer variables.
    promise = Promise.timer(timeout)
    {promise, promise.cancel}
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
end
