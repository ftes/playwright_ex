# upstream: packages/playwright-core/src/client/localUtils.ts
defmodule PlaywrightJS.Client.LocalUtils do
  use PlaywrightJS.Client.ChannelOwner

  # upstream: localUtils.ts:34
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :devices, Map.new(initializer[:deviceDescriptors] || [], fn %{name: name, descriptor: descriptor} -> {name, descriptor} end))
    this
  end

  # zip, harOpen, harLookup, harClose, harUnzip, tracingStarted, traceDiscarded  -- not ported

  # upstream: localUtils.ts:74
  def add_stack_to_tracing_no_reply(this, params) do
    channel_call(this, :addStackToTracingNoReply, params, TimeoutSettings.k_no_timeout())
  end

  # Not in the JS class (JS runs isomorphic/urlMatch.ts in-process); as in the Java and
  # Python clients, the driver resolves globs and renders locators.
  def glob_to_regex(this, glob, base_url \\ nil, web_socket_url \\ nil) do
    channel_call(this, :globToRegex, %{glob: glob, baseURL: base_url, webSocketUrl: web_socket_url}, TimeoutSettings.k_no_timeout()).regex
  end

  def as_locator_description(this, selector, sdk_language \\ "python") do
    channel_call(this, :asLocatorDescription, %{selector: selector, sdkLanguage: sdk_language}, TimeoutSettings.k_no_timeout()).description
  end
end
