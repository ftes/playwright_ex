defmodule PlaywrightEx.Client.Coverage do
  @upstream "packages/playwright-core/src/client/coverage.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct (`_channel` is the page)."
  import PlaywrightEx.Client.ChannelOwner, only: [channel_call: 4]

  alias PlaywrightEx.Client.TimeoutSettings

  defstruct [:_channel]

  def new(channel) do
    %__MODULE__{_channel: channel}
  end

  def start_js_coverage(this, options \\ %{}) do
    channel_call(this._channel, :startJSCoverage, options || %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def stop_js_coverage(this) do
    channel_call(this._channel, :stopJSCoverage, %{}, TimeoutSettings.k_no_timeout()).entries
  end

  def start_css_coverage(this, options \\ %{}) do
    channel_call(this._channel, :startCSSCoverage, options || %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def stop_css_coverage(this) do
    channel_call(this._channel, :stopCSSCoverage, %{}, TimeoutSettings.k_no_timeout()).entries
  end
end
