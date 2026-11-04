defmodule PlaywrightEx.Client.LocalUtils do
  @upstream "packages/playwright-core/src/client/localUtils.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)

    put(
      this,
      :devices,
      Map.new(initializer[:deviceDescriptors] || [], fn %{name: name, descriptor: descriptor} -> {name, descriptor} end)
    )

    this
  end

  # zip, harOpen, harLookup, harClose, harUnzip, connect, tracingStarted, traceDiscarded, globToRegex  -- not ported

  def add_stack_to_tracing_no_reply(this, params) do
    channel_call(this, :addStackToTracingNoReply, params, TimeoutSettings.k_no_timeout())
  end
end
