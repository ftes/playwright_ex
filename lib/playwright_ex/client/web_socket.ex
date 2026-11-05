defmodule PlaywrightEx.Client.WebSocket do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `WebSocket` in `#{@upstream}`.

  A frame payload is a string, or `{:binary, bytes}` for a JS `Buffer` (PLAN, Decisions).
  """
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.WebSocket

  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Waiter

  def from(web_socket) do
    web_socket
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_isClosed, false)
    put(this, :_page, parent)

    EventEmitter.on(_channel(this), "frameSent", fn event ->
      cond do
        event.opcode == 1 ->
          emit(this, Events.WebSocket.frame_sent(), %{payload: event.data})

        event.opcode == 2 ->
          emit(this, Events.WebSocket.frame_sent(), %{payload: {:binary, Base.decode64!(event.data)}})

        true ->
          nil
      end
    end)

    EventEmitter.on(_channel(this), "frameReceived", fn event ->
      cond do
        event.opcode == 1 ->
          emit(this, Events.WebSocket.frame_received(), %{payload: event.data})

        event.opcode == 2 ->
          emit(this, Events.WebSocket.frame_received(), %{payload: {:binary, Base.decode64!(event.data)}})

        true ->
          nil
      end
    end)

    EventEmitter.on(_channel(this), "socketError", fn %{error: error} -> emit(this, Events.WebSocket.error(), error) end)

    EventEmitter.on(_channel(this), "close", fn _ ->
      put(this, :_isClosed, true)
      emit(this, Events.WebSocket.close(), this)
    end)

    this
  end

  def url(this) do
    get(this, :_initializer).url
  end

  def is_closed(this) do
    # deviation: a disposed web socket reads its last state (its rows are gone).
    get(this, :_isClosed, true)
  end

  def wait_for_event(this, event, options_or_predicate \\ %{}) do
    options_or_predicate = options_or_predicate || %{}

    _wrap_api_call(this, fn _ ->
      page = get(this, :_page)

      timeout_options =
        TimeoutSettings.timeout(
          get(page, :_timeoutSettings),
          if(is_function(options_or_predicate), do: %{}, else: options_or_predicate)
        )

      predicate = if is_function(options_or_predicate), do: options_or_predicate, else: options_or_predicate[:predicate]
      waiter = Waiter.create_for_event(this, event)

      Waiter.reject_on_timeout(
        waiter,
        timeout_options,
        ~s(Timeout #{timeout_options.timeout}ms exceeded while waiting for event "#{event}")
      )

      if event != Events.WebSocket.error(),
        do: Waiter.reject_on_event(waiter, this, Events.WebSocket.error(), %RuntimeError{message: "Socket error"})

      if event != Events.WebSocket.close(),
        do: Waiter.reject_on_event(waiter, this, Events.WebSocket.close(), %RuntimeError{message: "Socket closed"})

      Waiter.reject_on_event(waiter, page, Events.Page.close(), fn -> Page._close_error_with_reason(page) end)
      result = Waiter.wait_for_event(waiter, this, event, predicate)
      Waiter.dispose(waiter)
      result
    end)
  end
end
