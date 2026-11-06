defmodule PlaywrightEx.Client.Clock do
  @upstream "packages/playwright-core/src/client/clock.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."
  import PlaywrightEx.Client.ChannelOwner, only: [channel_call: 4]

  alias PlaywrightEx.Client.TimeoutSettings

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.Clock{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_browserContext]

  def new(browser_context) do
    %PlaywrightEx.Clock{_browserContext: browser_context}
  end

  def install(this, options \\ %{}) do
    options = options || %{}

    channel_call(
      this._browserContext,
      :clockInstall,
      if(options[:time] != nil, do: parse_time(options.time), else: %{}),
      TimeoutSettings.k_no_timeout()
    )

    nil
  end

  def fast_forward(this, ticks) do
    channel_call(this._browserContext, :clockFastForward, parse_ticks(ticks), TimeoutSettings.k_no_timeout())
    nil
  end

  def pause_at(this, time) do
    channel_call(this._browserContext, :clockPauseAt, parse_time(time), TimeoutSettings.k_no_timeout())
    nil
  end

  def resume(this) do
    channel_call(this._browserContext, :clockResume, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def run_for(this, ticks) do
    channel_call(this._browserContext, :clockRunFor, parse_ticks(ticks), TimeoutSettings.k_no_timeout())
    nil
  end

  def set_fixed_time(this, time) do
    channel_call(this._browserContext, :clockSetFixedTime, parse_time(time), TimeoutSettings.k_no_timeout())
    nil
  end

  def set_system_time(this, time) do
    channel_call(this._browserContext, :clockSetSystemTime, parse_time(time), TimeoutSettings.k_no_timeout())
    nil
  end

  # A JS `Date` is a `DateTime`.
  defp parse_time(time) when is_number(time), do: %{timeNumber: time}
  defp parse_time(time) when is_binary(time), do: %{timeString: time}
  # if (!isFinite(time.getTime())) throw new Error(`Invalid date: ${time}`);  -- not ported: a DateTime is always valid
  defp parse_time(%DateTime{} = time), do: %{timeNumber: DateTime.to_unix(time, :millisecond)}

  defp parse_ticks(ticks) do
    %{
      ticksNumber: if(is_number(ticks), do: ticks),
      ticksString: if(is_binary(ticks), do: ticks)
    }
  end
end
