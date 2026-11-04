defmodule PlaywrightEx.Client.BrowserType do
  @upstream "packages/playwright-core/src/client/browserType.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.Browser

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_contexts, [])
    this
  end

  def from(browser_type) do
    browser_type
  end

  def executable_path(this) do
    if !get(this, :_initializer)[:executablePath], do: raise("Browser is not supported on current platform")
    get(this, :_initializer).executablePath
  end

  def name(this) do
    get(this, :_initializer).name
  end

  def launch(this, options \\ %{}) do
    if options[:userDataDir],
      do:
        raise(
          "userDataDir option is not supported in `browserType.launch`. Use `browserType.launchPersistentContext` instead"
        )

    if options[:port], do: raise("Cannot specify a port without launching as a server.")

    logger = options[:logger] || (get(get(this, :_playwright), :_defaultLaunchOptions) || %{})[:logger]
    options = Map.merge(get(get(this, :_playwright), :_defaultLaunchOptions) || %{}, options)

    launch_options =
      Map.merge(options, %{
        ignoreDefaultArgs: if(is_list(options[:ignoreDefaultArgs]), do: options[:ignoreDefaultArgs]),
        ignoreAllDefaultArgs: !!options[:ignoreDefaultArgs] and !is_list(options[:ignoreDefaultArgs]),
        env:
          if(options[:env],
            do: Enum.map(options[:env], fn {name, value} -> %{name: to_string(name), value: to_string(value)} end)
          )
      })

    _wrap_api_call(this, fn _ ->
      browser =
        Browser.from(
          channel_call(this, :launch, launch_options, TimeoutSettings.launch_timeout(TimeoutSettings.new(nil), options)).browser
        )

      Browser._connect_to_browser_type(browser, this, options, logger)
      browser
    end)
  end

  # launchServer, launchPersistentContext, connect, _connect, connectOverCDP  -- not ported
end
