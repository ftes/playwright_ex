defmodule PlaywrightEx.Client.Worker do
  @upstream "packages/playwright-core/src/client/worker.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.ConsoleMessage
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.LongStandingScope

  def from_nullable(worker) do
    if worker, do: from(worker)
  end

  def from(worker) do
    worker
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    # Set for web workers.
    put(this, :_page, nil)
    # Set for service workers.
    put(this, :_context, nil)
    put(this, :_closedScope, LongStandingScope.new())
    put(this, :_closeReason, nil)
    _set_event_to_subscription_mapping(this, %{Events.Worker.console() => "console"})

    EventEmitter.on(_channel(this), "console", fn event ->
      # Note: we only receive console events here for workers from "chromium._connectToWorker".
      emit(this, Events.Worker.console(), ConsoleMessage.new(event, nil, this))
    end)

    EventEmitter.on(_channel(this), "close", fn _ ->
      if page = get(this, :_page), do: set_delete(page, :_workers, this)
      if context = get(this, :_context), do: set_delete(context, :_serviceWorkers, this)
      emit(this, Events.Worker.close(), this)
    end)

    once(this, Events.Worker.close(), fn _ ->
      LongStandingScope.close(get(this, :_closedScope), _close_error_with_reason(this))
    end)

    this
  end

  def _close_error_with_reason(this) do
    if close_reason = get(this, :_closeReason) do
      Errors.TargetClosedError.new(close_reason)
    else
      page = get(this, :_page)
      (page && Page._close_error_with_reason(page)) || Errors.TargetClosedError.new()
    end
  end

  def url(this) do
    get(this, :_initializer).url
  end

  def evaluate(this, page_function, arg \\ nil) do
    # assertMaxArguments(arguments.length, 2);  -- not ported: Elixir arities are fixed
    # isFunction: typeof pageFunction === 'function'  -- omitted: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evaluateExpression,
        %{expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  def evaluate_handle(this, page_function, arg \\ nil) do
    # assertMaxArguments(arguments.length, 2);  -- not ported: Elixir arities are fixed
    # isFunction: typeof pageFunction === 'function'  -- omitted: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evaluateExpressionHandle,
        %{expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.from(result.handle)
  end

  # waitForEvent  -- not ported: waits for the promise handle (PLAN, Public API)

  def _disconnect(this, options \\ %{}) do
    put(this, :_closeReason, options[:reason])

    try do
      channel_call(this, :disconnect, options, TimeoutSettings.k_no_timeout())
    rescue
      e -> if Errors.is_target_closed_error(e), do: nil, else: reraise(e, __STACKTRACE__)
    end

    nil
  end
end
