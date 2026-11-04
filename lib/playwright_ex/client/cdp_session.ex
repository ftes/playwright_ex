defmodule PlaywrightEx.Client.CDPSession do
  @upstream "packages/playwright-core/src/client/cdpSession.ts"
  @moduledoc """
  Port of `#{@upstream}`. CDP events are emitted under their method names
  (`"Network.requestWillBeSent"`) with the raw params (string keys, JSON as the driver sends it).
  """
  use PlaywrightEx.Client.ChannelOwner

  def from(cdp_session) do
    cdp_session
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)

    EventEmitter.on(_channel(this), "event", fn event ->
      emit(this, event.method, event[:params])
      emit(this, "event", event)
    end)

    EventEmitter.on(_channel(this), "close", fn _ ->
      emit(this, "close", this)
    end)

    # this.on = super.on; this.addListener = ...; this.off = super.removeListener; ...  -- not ported: TS overload plumbing
    this
  end

  def send(this, method, params \\ nil) do
    result = channel_call(this, :send, %{method: method, params: params}, TimeoutSettings.k_no_timeout())
    result.result
  end

  def detach(this) do
    channel_call(this, :detach, %{}, TimeoutSettings.k_no_timeout())
    nil
  end
end
