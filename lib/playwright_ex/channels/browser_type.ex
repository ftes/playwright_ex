defmodule PlaywrightEx.BrowserType do
  @moduledoc """
  Interact with a Playwright `BrowserType`.

  There is no official documentation, since this is considered Playwright internal.

  Reference: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/browserType.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  @type guid :: String.t()

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      channel: [
        type: :string,
        doc: "Browser distribution channel."
      ],
      executable_path: [
        type: :string,
        doc: "Path to a browser executable to run instead of the bundled one."
      ],
      headless: [
        type: :boolean,
        doc: "Whether to run browser in headless mode."
      ],
      slow_mo: [
        type: {:or, [:integer, :float]},
        doc: "Slows down Playwright operations by the specified amount of milliseconds."
      ]
    )

  @doc """
  Launches a new browser instance.

  Reference: https://playwright.dev/docs/api/class-browsertype#browser-type-launch

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type launch_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec launch(PlaywrightEx.guid(), [launch_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid()}} | {:error, any()}
  def launch(type_id, opts \\ []) do
    {connection, opts} =
      opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: type_id, method: :launch, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap_create(:browser, connection)
  end

  @doc false
  def launch_opts_schema, do: @schema

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      user_data_dir: [
        type: :string,
        required: true,
        doc: "Path to a user data directory, which stores browser session data such as cookies and local storage."
      ],
      channel: [
        type: :string,
        doc: "Browser distribution channel."
      ],
      executable_path: [
        type: :string,
        doc: "Path to a browser executable to run instead of the bundled one."
      ],
      headless: [
        type: :boolean,
        doc: "Whether to run browser in headless mode. Defaults to false for persistent contexts."
      ],
      slow_mo: [
        type: {:or, [:integer, :float]},
        doc: "Slows down Playwright operations by the specified amount of milliseconds."
      ],
      accept_downloads: [
        type: :boolean,
        doc: "Whether to automatically download all the attachments. Defaults to true."
      ],
      base_url: [
        type: :string,
        doc: "Base URL used with Page.goto/2 and similar navigation functions."
      ],
      bypass_csp: [
        type: :boolean,
        doc: "Toggles bypassing page's Content-Security-Policy. Defaults to false."
      ],
      locale: [
        type: :string,
        doc: "Specify user locale, for example en-GB, de-DE, etc."
      ],
      user_agent: [
        type: :string,
        doc: "Specific user agent to use in this context."
      ],
      viewport: [
        type: :any,
        doc: "Sets a consistent viewport for each page. Map with :width and :height, or nil to disable."
      ],
      ignore_https_errors: [
        type: :boolean,
        doc: "Whether to ignore HTTPS errors when sending network requests."
      ],
      java_script_enabled: [
        type: :boolean,
        doc: "Whether or not to enable JavaScript in the context. Defaults to true."
      ]
    )

  @doc """
  Launches a browser and opens a persistent context using the given user data directory.

  Reference: https://playwright.dev/docs/api/class-browsertype#browser-type-launch-persistent-context

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type launch_persistent_context_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec launch_persistent_context(PlaywrightEx.guid(), [launch_persistent_context_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid(), tracing: %{guid: PlaywrightEx.guid()}}} | {:error, any()}
  def launch_persistent_context(type_id, opts \\ []) do
    {connection, opts} =
      opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: type_id, method: :launch_persistent_context, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap_create(:context, connection)
  end

  @doc false
  def launch_persistent_context_opts_schema, do: @schema

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      endpoint_url: [
        type: :string,
        required: true,
        doc: "A CDP websocket endpoint or http url to connect to. For example ws://localhost:9222/ or http://localhost:9222/."
      ],
      headers: [
        type: :any,
        doc: "Additional HTTP headers to be sent with connect request. Often used for authorization."
      ],
      slow_mo: [
        type: {:or, [:integer, :float]},
        doc: "Slows down Playwright operations by the specified amount of milliseconds. Useful so that you can see what is going on."
      ]
    )

  @doc """
  Connects to an existing browser instance using the Chrome DevTools Protocol endpoint.

  Reference: https://playwright.dev/docs/api/class-browsertype#browser-type-connect-over-cdp

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type connect_over_cdp_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec connect_over_cdp(PlaywrightEx.guid(), [connect_over_cdp_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid()}} | {:error, any()}
  def connect_over_cdp(type_id, opts \\ []) do
    {connection, opts} =
      opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    params =
      opts
      |> Map.new()
      |> Map.put(:endpointURL, opts[:endpoint_url])
      |> Map.delete(:endpoint_url)

    connection
    |> Connection.send(%{guid: type_id, method: :connectOverCDP, params: params}, timeout)
    |> ChannelResponse.unwrap_create(:browser, connection)
  end

  @doc false
  def connect_over_cdp_opts_schema, do: @schema
end
