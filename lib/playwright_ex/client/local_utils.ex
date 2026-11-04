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

  # zip, harOpen, harLookup, harClose, harUnzip, connect, tracingStarted, traceDiscarded  -- not ported

  def add_stack_to_tracing_no_reply(this, params) do
    channel_call(this, :addStackToTracingNoReply, params, TimeoutSettings.k_no_timeout())
  end

  # Elixir only: the JS client converts URL globs itself (isomorphic/urlMatch.ts). Here the driver
  # does, as in the non-JS clients (PLAN, Decisions); the regex source is cached per glob.
  def glob_to_regex(this, params) do
    key = {params[:glob], params[:baseURL], params[:webSocketUrl]}

    map_get(this, :_globToRegex, key) ||
      map_set(this, :_globToRegex, key, channel_call(this, :globToRegex, params, TimeoutSettings.k_no_timeout()).regex)
  end
end
