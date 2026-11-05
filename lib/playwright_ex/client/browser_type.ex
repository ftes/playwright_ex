defmodule PlaywrightEx.Client.BrowserType do
  @upstream "packages/playwright-core/src/client/browserType.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.BrowserType

  alias PlaywrightEx.Client.Browser
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Client.Connect
  alias PlaywrightEx.Client.Selectors
  alias PlaywrightEx.Client.Worker
  alias PlaywrightEx.Isomorphic.Headers

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
        env: if(options[:env], do: env_object_to_array(options[:env]))
      })

    _wrap_api_call(this, fn _ ->
      browser =
        ChannelOwner._set_creator(
          Browser.from(
            channel_call(
              this,
              :launch,
              launch_options,
              TimeoutSettings.launch_timeout(TimeoutSettings.new(nil), options)
            ).browser
          )
        )

      Browser._connect_to_browser_type(browser, this, options, logger)
      browser
    end)
  end

  # launchServer  -- not ported: BrowserServer (PLAN: out of scope)

  def launch_persistent_context(this, user_data_dir, options \\ %{}) do
    if options[:port], do: raise("Cannot specify a port without launching as a server.")

    options =
      Selectors._with_selector_options(
        get(get(this, :_playwright), :selectors),
        Map.merge(get(get(this, :_playwright), :_defaultLaunchOptions) || %{}, options)
      )

    # await this._instrumentation.runBeforeCreateBrowserContext(options);  -- not ported: instrumentation

    logger = options[:logger] || (get(get(this, :_playwright), :_defaultLaunchOptions) || %{})[:logger]
    context_params = BrowserContext.prepare_browser_context_params(options)

    persistent_params =
      Map.merge(context_params, %{
        ignoreDefaultArgs: if(is_list(options[:ignoreDefaultArgs]), do: options[:ignoreDefaultArgs]),
        ignoreAllDefaultArgs: !!options[:ignoreDefaultArgs] and !is_list(options[:ignoreDefaultArgs]),
        env: if(options[:env], do: env_object_to_array(options[:env])),
        channel: options[:channel],
        userDataDir:
          if(Path.type(user_data_dir) == :absolute or user_data_dir == "",
            do: user_data_dir,
            else: Path.expand(user_data_dir)
          )
      })

    context =
      _wrap_api_call(this, fn _ ->
        # The statements up to the next await run on reply, before the context's events
        # (`channel_call/5`): its close reads the browser type.
        result =
          channel_call(
            this,
            :launchPersistentContext,
            persistent_params,
            TimeoutSettings.launch_timeout(TimeoutSettings.new(nil), options),
            fn result ->
              browser = Browser.from(result.browser)
              Browser._connect_to_browser_type(browser, this, options, logger)
            end
          )

        ChannelOwner._set_creator(Browser.from(result.browser))
        context = ChannelOwner._set_creator(BrowserContext.from(result.context))
        BrowserContext._initialize_har_from_options(context, options[:recordHar])
        context
      end)

    # await this._instrumentation.runAfterCreateBrowserContext(context);  -- not ported: instrumentation
    context
  end

  def connect(this, options_or_endpoint, options \\ %{}) do
    if is_binary(options_or_endpoint) do
      _connect(this, Map.put(options, :endpoint, options_or_endpoint))
    else
      if !options_or_endpoint[:wsEndpoint], do: raise("options.wsEndpoint is required")
      _connect(this, Map.put(options_or_endpoint, :endpoint, options_or_endpoint.wsEndpoint))
    end
  end

  def _connect(this, params) do
    _wrap_api_call(this, fn _ ->
      browser =
        ChannelOwner._set_creator(
          Connect.connect_to_browser(get(this, :_playwright), Map.merge(%{browserName: name(this)}, params))
        )

      Browser._connect_to_browser_type(browser, this, %{}, nil)
      browser
    end)
  end

  def connect_over_cdp(this, overloaded, options \\ %{}) do
    {endpoint_url, params} =
      if is_binary(overloaded) do
        {overloaded, options}
      else
        # else if (isConnectionTransport(overloaded)) { ... }  -- not ported: connectOverCDP(transport) (PLAN: out of scope)
        endpoint_url =
          if Map.has_key?(overloaded, :endpointURL), do: overloaded.endpointURL, else: overloaded[:wsEndpoint]

        if !endpoint_url, do: raise("Cannot connect over CDP without wsEndpoint.")
        {endpoint_url, overloaded}
      end

    # `endpointURL && ...`: always set here (no transport branch).
    if name(this) != "chromium" && name(this) != "webkit",
      do: raise("Connecting over CDP is only supported in Chromium and WebKit.")

    # The statements up to the next await run on reply, before the contexts' events
    # (`channel_call/5`): their close reads the browser type.
    result =
      channel_call(
        this,
        :connectOverCDP,
        %{
          endpointURL: endpoint_url,
          # transport: transport as any,  -- not ported: connectOverCDP(transport)
          headers: if(params[:headers], do: Headers.headers_object_to_array(params.headers)),
          slowMo: params[:slowMo],
          isLocal: params[:isLocal],
          noDefaults: params[:noDefaults],
          isWebView: params[:isWebView],
          artifactsDir: params[:artifactsDir]
        },
        TimeoutSettings.timeout(TimeoutSettings.new(nil), params),
        fn result -> _browser_from_connect_result(this, result) end
      )

    ChannelOwner._set_creator(Browser.from(result.browser))
  end

  defp _browser_from_connect_result(this, result) do
    browser = Browser.from(result.browser)
    Browser._connect_to_browser_type(browser, this, %{}, nil)

    # if (result.defaultContext) await this._instrumentation.runAfterCreateBrowserContext(...)  -- not ported: instrumentation
    browser
  end

  def _connect_to_worker(this, endpoint, options \\ %{}) do
    if name(this) != "chromium", do: raise("Connecting to workers is only supported in Chromium.")

    result =
      channel_call(
        this,
        :connectToWorker,
        %{endpoint: endpoint},
        TimeoutSettings.timeout(TimeoutSettings.new(nil), options)
      )

    Worker.from(result.worker)
  end

  # isConnectionTransport  -- not ported: connectOverCDP(transport) (PLAN: out of scope)

  # clientHelper.ts envObjectToArray
  defp env_object_to_array(env) do
    for {name, value} <- env,
        value != nil,
        do: %{
          name: to_string(name),
          value: if(is_number(value), do: ClientHelper.number_to_string(value), else: to_string(value))
        }
  end
end
