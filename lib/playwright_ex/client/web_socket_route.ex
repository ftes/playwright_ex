defmodule PlaywrightEx.Client.WebSocketRoute do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `WebSocketRoute` in `#{@upstream}`.

  A message is a string, or `{:binary, bytes}` for a JS `Buffer` (PLAN, Decisions).

  Deviation: `this._server` (an object literal implementing the same interface) is a handle
  of this module whose guid is the route's prefixed with `"server:"`; the public members
  dispatch on it.
  """
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.WebSocketRoute


  def from(route) do
    route
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_connected, false)
    put(this, :_server, %{this | guid: "server:" <> guid})

    EventEmitter.on(_channel(this), "messageFromPage", fn %{message: message, isBase64: is_base64} ->
      cond do
        get(this, :_onPageMessage) ->
          get(this, :_onPageMessage).(if is_base64, do: {:binary, Base.decode64!(message)}, else: message)

        get(this, :_connected) ->
          _fire_and_forget(this, :sendToServer, %{message: message, isBase64: is_base64})

        true ->
          nil
      end
    end)

    EventEmitter.on(_channel(this), "messageFromServer", fn %{message: message, isBase64: is_base64} ->
      if get(this, :_onServerMessage),
        do: get(this, :_onServerMessage).(if is_base64, do: {:binary, Base.decode64!(message)}, else: message),
        else: _fire_and_forget(this, :sendToPage, %{message: message, isBase64: is_base64})
    end)

    EventEmitter.on(_channel(this), "closePage", fn %{wasClean: was_clean} = event ->
      if get(this, :_onPageClose),
        do: get(this, :_onPageClose).(event[:code], event[:reason]),
        else: _fire_and_forget(this, :closeServer, %{code: event[:code], reason: event[:reason], wasClean: was_clean})
    end)

    EventEmitter.on(_channel(this), "closeServer", fn %{wasClean: was_clean} = event ->
      if get(this, :_onServerClose),
        do: get(this, :_onServerClose).(event[:code], event[:reason]),
        else: _fire_and_forget(this, :closePage, %{code: event[:code], reason: event[:reason], wasClean: was_clean})
    end)

    this
  end

  # this._server = { onMessage, onClose, connectToServer, url, protocols, close, send }: the
  # clauses for `"server:" <> guid` handles below.
  defp _route(%{guid: "server:" <> guid} = server), do: %{server | guid: guid}

  def url(%{guid: "server:" <> _} = server), do: get(_route(server), :_initializer).url

  def url(this) do
    get(this, :_initializer).url
  end

  def protocols(%{guid: "server:" <> _} = server), do: get(_route(server), :_initializer).protocols

  def protocols(this) do
    get(this, :_initializer).protocols
  end

  def close(this, options \\ %{})

  def close(%{guid: "server:" <> _} = server, options) do
    try do
      channel_call(
        _route(server),
        :closeServer,
        Map.merge(options || %{}, %{wasClean: true}),
        TimeoutSettings.k_no_timeout()
      )
    rescue
      _ -> nil
    end

    nil
  end

  def close(this, options) do
    try do
      channel_call(this, :closePage, Map.merge(options || %{}, %{wasClean: true}), TimeoutSettings.k_no_timeout())
    rescue
      _ -> nil
    end

    nil
  end

  def connect_to_server(%{guid: "server:" <> _}) do
    raise "connectToServer must be called on the page-side WebSocketRoute"
  end

  def connect_to_server(this) do
    atomic(this, fn ->
      if get(this, :_connected), do: raise("Already connected to the server")
      put(this, :_connected, true)
      _fire_and_forget(this, :connect, %{})
      get(this, :_server)
    end)
  end

  def send(%{guid: "server:" <> _} = server, message) do
    route = _route(server)

    atomic(route, fn ->
      if is_binary(message),
        do: _fire_and_forget(route, :sendToServer, %{message: message, isBase64: false}),
        else: _fire_and_forget(route, :sendToServer, %{message: Base.encode64(elem(message, 1)), isBase64: true})
    end)

    nil
  end

  def send(this, message) do
    atomic(this, fn ->
      if is_binary(message),
        do: _fire_and_forget(this, :sendToPage, %{message: message, isBase64: false}),
        else: _fire_and_forget(this, :sendToPage, %{message: Base.encode64(elem(message, 1)), isBase64: true})
    end)

    nil
  end

  def on_message(%{guid: "server:" <> _} = server, handler) do
    put(_route(server), :_onServerMessage, handler)
    nil
  end

  def on_message(this, handler) do
    put(this, :_onPageMessage, handler)
    nil
  end

  def on_close(%{guid: "server:" <> _} = server, handler) do
    put(_route(server), :_onServerClose, handler)
    nil
  end

  def on_close(this, handler) do
    put(this, :_onPageClose, handler)
    nil
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def _after_handle(this) do
    if !get(this, :_connected) do
      # Ensure that websocket is "open" and can send messages without an actual server connection.
      # If this happens after the page has been closed, ignore the error.
      try do
        channel_call(this, :ensureOpened, %{}, TimeoutSettings.k_no_timeout())
      rescue
        _ -> nil
      end
    end

    nil
  end

  # `this._channel.<method>(params, kNoTimeout).catch(() => {})`, not awaited.
  defp _fire_and_forget(this, method, params) do
    Promise.void(fn -> channel_call(this, method, params, TimeoutSettings.k_no_timeout()) end)

    nil
  end
end
