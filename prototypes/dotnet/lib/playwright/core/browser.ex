defmodule Playwright.Core.Browser do
  @moduledoc "upstream: Core/Browser.cs"
  use Playwright.Transport.ChannelOwner, [:initializer]

  alias Playwright.Core.BrowserContext
  alias Playwright.Core.DriverMessages
  alias Playwright.Helpers.TaskCompletionSource
  alias Playwright.PlaywrightException
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Connection
  alias Playwright.Transport.Converters
  import ChannelOwner, only: [get: 2, set: 3, update: 3, emit: 3]

  # upstream: Core/Browser.cs:48
  def new(parent, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, guid, initializer: initializer)
    set(this, :contexts, [])
    set(this, :is_connected, true)
    # _onConnectionClose = (_, _) => DidClose(); _connection.Close += _onConnectionClose;
    ChannelOwner.add_handler(Connection.get_object(this.connection, ""), "Close", fn _ -> did_close(this) end)
    this
  end

  # private readonly TaskCompletionSource<bool> _closedTcs = new();
  defp closed_tcs(this), do: TaskCompletionSource.new(this, :closed_tcs)

  # events (Browser.cs:56 Disconnected, :58 Context) have no function: emit(this, "Disconnected" | "Context", _)

  # upstream: Core/Browser.cs:60
  def contexts(this), do: get(this, :contexts)

  # upstream: Core/Browser.cs:62
  def is_connected(this), do: get(this, :is_connected)

  # upstream: Core/Browser.cs:66
  def version(this), do: this.initializer.version

  # upstream: Core/Browser.cs:68
  def browser_type(this), do: get(this, :browser_type)

  # upstream: Core/Browser.cs:70
  @impl true
  def on_message(this, method, server_params) do
    case method do
      "context" ->
        did_create_context(this, Converters.to_channel_owner(server_params["context"], this.connection))
      "close" ->
        did_close(this)
      _ ->
        :ok
    end
  end

  # upstream: Core/Browser.cs:84
  def close(this, options \\ nil) do
    set(this, :close_reason, options[:reason])
    try do
      if get(this, :should_close_connection_on_close) do
        Connection.dispose(this.connection)
      else
        ChannelOwner.send_message_to_server(this, "close", %{
          "reason" => options[:reason],
        })
      end
      TaskCompletionSource.await(closed_tcs(this))
    rescue
      e -> if DriverMessages.is_target_closed_error(e), do: :ok, else: reraise(e, __STACKTRACE__)
    end
  end

  # upstream: Core/Browser.cs:109
  def new_context(this, options \\ nil) do
    options = options || []

    args = %{
      "bypassCSP" => options[:bypass_csp],
      "deviceScaleFactor" => options[:device_scale_factor],
      "serviceWorkers" => options[:service_workers],
      "geolocation" => options[:geolocation],
      "hasTouch" => options[:has_touch],
      "httpCredentials" => to_http_credentials_protocol(options[:http_credentials], options[:http_credentials_list]),
      "ignoreHTTPSErrors" => options[:ignore_https_errors],
      "isMobile" => options[:is_mobile],
      "javaScriptEnabled" => options[:java_script_enabled],
      "locale" => options[:locale],
      "offline" => options[:offline],
      "permissions" => options[:permissions],
      "proxy" => options[:proxy],
      "strictSelectors" => options[:strict_selectors],
      "colorScheme" => if(options[:color_scheme] == :null, do: "no-override", else: options[:color_scheme]),
      "reducedMotion" => if(options[:reduced_motion] == :null, do: "no-override", else: options[:reduced_motion]),
      "forcedColors" => if(options[:forced_colors] == :null, do: "no-override", else: options[:forced_colors]),
      "contrast" => if(options[:contrast] == :null, do: "no-override", else: options[:contrast]),
      "extraHTTPHeaders" => options[:extra_http_headers] && Enum.map(options[:extra_http_headers], fn {k, v} -> %{"name" => k, "value" => v} end),
      "recordVideo" => get_video_args(options[:record_video_dir], options[:record_video_size], options[:record_video_fps]),
      "timezoneId" => options[:timezone_id],
      "userAgent" => options[:user_agent],
      "baseURL" => options[:base_url],
      "clientCertificates" => to_client_certificates_protocol(options[:client_certificates]),
      "selectorEngines" => get(get(this, :browser_type), :playwright).selectors.selector_engines,
      "testIdAttributeName" => get(get(this, :browser_type), :playwright).selectors.test_id_attribute_name,
    }

    args = if options[:accept_downloads] != nil do
      Map.put(args, "acceptDownloads", if(options[:accept_downloads], do: "accept", else: "deny"))
    else
      args
    end

    storage_state = options[:storage_state]
    storage_state = if options[:storage_state_path] not in [nil, ""] do
      if !File.exists?(options[:storage_state_path]) do
        raise PlaywrightException.new("The specified storage state file does not exist: #{options[:storage_state_path]}")
      end

      File.read!(options[:storage_state_path])
    else
      storage_state
    end

    args = if storage_state not in [nil, ""] do
      Map.put(args, "storageState", JSON.decode!(storage_state))
    else
      args
    end

    args = if options[:viewport_size][:width] == -1 do
      Map.put(args, "noDefaultViewport", true)
    else
      args
      |> Map.put("viewport", options[:viewport_size])
      |> Map.put("screen", options[:screen_size])
    end

    context = ChannelOwner.send_message_to_server(this, "newContext", args, as: BrowserContext)
    BrowserContext.initialize_har_from_options_async(context, options)
    context
  end

  # upstream: Core/Browser.cs:180
  def new_page(this, options \\ nil) do
    options = options || []

    # C# copies 40 BrowserNewPageOptions properties into BrowserNewContextOptions; keyword lists share one shape.
    context_options = options

    ChannelOwner.wrap_api_call(
      this,
      fn ->
        context = new_context(this, context_options)
        page = BrowserContext.new_page(context)
        set(page, :owned_context, context)
        set(context, :owner_page, page)
        page
      end,
      false,
      "Create page")
  end

  # upstream: Core/Browser.cs:241
  def dispose_async(this), do: close(this)

  # upstream: Core/Browser.cs:243
  def get_video_args(record_video_dir, record_video_size, record_video_fps) do
    if record_video_size != nil and record_video_dir in [nil, ""] do
      raise PlaywrightException.new("\"RecordVideoSize\" option requires \"RecordVideoDir\" to be specified")
    end

    if record_video_fps != nil and record_video_dir in [nil, ""] do
      raise PlaywrightException.new("\"RecordVideoFps\" option requires \"RecordVideoDir\" to be specified")
    end

    if record_video_dir not in [nil, ""] do
      record_video_args = %{"dir" => Path.expand(record_video_dir)}
      record_video_args = if record_video_size != nil, do: Map.put(record_video_args, "size", record_video_size), else: record_video_args
      if record_video_fps != nil, do: Map.put(record_video_args, "fps", record_video_fps), else: record_video_args
    end
  end

  # upstream: Core/Browser.cs:278
  def connect_to_browser_type(this, browser_type, traces_dir) do
    # Note: when using connect(), `browserType` is different from `this.parent`.
    # This is why browser type is not wired up in the constructor, and instead this separate method is called later on.
    set(this, :browser_type, browser_type)
    set(this, :traces_dir, traces_dir)
    for _context <- get(this, :contexts) do
      # skipped: context._tracing._tracesDir / context._request._tracing._tracesDir (Tracing not ported)
      # skipped: browserType.Playwright._selectors._contextsForSelectors.Add(context);
      :ok
    end
  end

  # upstream: Core/Browser.cs:292
  defp did_create_context(this, context) do
    set(context, :browser, this)
    update(this, :contexts, &(&1 ++ [context]))
    # Note: when connecting to a browser, initial contexts arrive before `_browserType` is set,
    # and will be configured later in `ConnectToBrowserType`.
    if get(this, :browser_type) != nil do
      # skipped: tracing dirs + _selectors._contextsForSelectors.Add(context)
      :ok
    end
    emit(this, "Context", context)
  end

  # upstream: Core/Browser.cs:307
  def did_close(this) do
    if get(this, :is_connected) do
      # skipped: _connection.Close -= _onConnectionClose; (DidClose is idempotent)
      set(this, :is_connected, false)
      emit(this, "Disconnected", this)
      TaskCompletionSource.try_set_result(closed_tcs(this), true)
    end
  end

  # upstream: Core/Browser.cs:342
  def to_client_certificates_protocol(nil), do: nil
  def to_client_certificates_protocol(_client_certificates), do: raise(PlaywrightException.new("ClientCertificates not ported"))

  # upstream: Core/Browser.cs:361
  def to_http_credentials_protocol(http_credentials, http_credentials_list) do
    list = http_credentials_list || if(http_credentials != nil, do: [http_credentials], else: nil)
    if list != nil and length(list) > 0, do: list, else: nil
  end
end
