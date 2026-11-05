defmodule PlaywrightEx.Client.Debugger do
  @upstream "packages/playwright-core/src/client/debugger.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.Debugger

  def from(channel) do
    channel
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_pausedDetails, nil)

    EventEmitter.on(_channel(this), "pausedStateChanged", fn event ->
      put(this, :_pausedDetails, event[:pausedDetails])
      emit(this, Events.Debugger.paused_state_changed())
    end)

    EventEmitter.on(_channel(this), "apiCallsUpdated", fn %{apiCalls: api_calls} ->
      emit(this, Events.Debugger.api_calls_updated(), api_calls)
    end)

    this
  end

  def _enable(this) do
    channel_call(this, :enable, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def request_pause(this) do
    channel_call(this, :requestPause, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def resume(this) do
    channel_call(this, :resume, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def next(this) do
    channel_call(this, :next, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def run_to(this, location) do
    channel_call(this, :runTo, %{location: location}, TimeoutSettings.k_no_timeout())
    nil
  end

  def paused_details(this) do
    get(this, :_pausedDetails)
  end
end
