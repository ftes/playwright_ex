defmodule PlaywrightEx.Client.LocalUtils do
  @upstream "packages/playwright-core/src/client/localUtils.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Runtime.EventLoop

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)

    put(
      this,
      :devices,
      Map.new(initializer[:deviceDescriptors] || [], fn %{name: name, descriptor: descriptor} -> {name, descriptor} end)
    )

    this
  end

  def zip(this, params) do
    channel_call(this, :zip, params, TimeoutSettings.k_no_timeout())
  end

  def har_open(this, params) do
    channel_call(this, :harOpen, params, TimeoutSettings.k_no_timeout())
  end

  def har_lookup(this, params) do
    channel_call(this, :harLookup, params, TimeoutSettings.k_no_timeout())
  end

  def har_close(this, params) do
    channel_call(this, :harClose, params, TimeoutSettings.k_no_timeout())
  end

  def har_unzip(this, params) do
    channel_call(this, :harUnzip, params, TimeoutSettings.k_no_timeout())
  end

  def tracing_started(this, params) do
    channel_call(this, :tracingStarted, params, TimeoutSettings.k_no_timeout())
  end

  def trace_discarded(this, params) do
    channel_call(this, :traceDiscarded, params, TimeoutSettings.k_no_timeout())
    nil
  end

  def add_stack_to_tracing_no_reply(this, params) do
    channel_call(this, :addStackToTracingNoReply, params, TimeoutSettings.k_no_timeout())
  end

  # Elixir only: the JS client converts URL globs itself (isomorphic/urlMatch.ts). Here the driver
  # does, as in the non-JS clients (PLAN, Decisions); the regex source is cached per glob.
  def glob_to_regex(this, params) do
    key = {params[:glob], params[:baseURL], params[:webSocketUrl]}

    # Under the baton: sync members (`page.frame({ url })`) match URLs without it.
    EventLoop.with_baton(this.loop, fn ->
      map_get(this, :_globToRegex, key) ||
        map_set(
          this,
          :_globToRegex,
          key,
          channel_call(this, :globToRegex, params, TimeoutSettings.k_no_timeout()).regex
        )
    end)
  end

  # Elixir only: the JS client renders locators itself (isomorphic/locatorGenerators.ts). Here the
  # driver does, as in the non-JS clients (PLAN, Decisions).
  def as_locator_description(this, params) do
    channel_call(this, :asLocatorDescription, params, TimeoutSettings.k_no_timeout()).description
  end
end
