defmodule PlaywrightEx do
  @moduledoc """
  Main entry point. Elixir client for the Playwright node.js driver.

  Use `launch_browser/2` to get started after adding `PlaywrightEx.Supervisor` to your supervision tree.

  See the [README](readme.html) for getting started and more details.
  """

  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Connection

  @type guid :: String.t()
  @type unknown_opt :: {Keyword.key(), Keyword.value()}

  @doc """
  Launches a new browser instance, or returns the pre-launched browser when
  connected to a remote Playwright server.

  ## Options

  #{NimbleOptions.docs(BrowserType.launch_opts_schema())}
  """
  @spec launch_browser(atom(), [BrowserType.launch_opt() | unknown_opt()]) :: {:ok, %{guid: guid()}} | {:error, any()}
  def launch_browser(type, opts) do
    {connection, opts} =
      opts |> PlaywrightEx.Channel.validate_known!(BrowserType.launch_opts_schema()) |> Keyword.pop!(:connection)

    playwright_init = Connection.initializer!(connection, "Playwright")

    case playwright_init do
      %{pre_launched_browser: %{guid: browser_guid}} ->
        # Remote server provides a pre-launched browser
        browser_init = Connection.initializer!(connection, browser_guid)
        {:ok, Map.put(browser_init, :guid, browser_guid)}

      _ ->
        type_id = playwright_init |> Map.fetch!(type) |> Map.fetch!(:guid)
        BrowserType.launch(type_id, opts ++ [connection: connection])
    end
  end

  @doc """
  Launches a browser and opens a persistent context using the given user data directory.

  ## Options

  #{NimbleOptions.docs(BrowserType.launch_persistent_context_opts_schema())}
  """
  @spec launch_persistent_context(atom(), [BrowserType.launch_persistent_context_opt() | unknown_opt()]) ::
          {:ok, %{guid: guid(), tracing: %{guid: guid()}}} | {:error, any()}
  def launch_persistent_context(type, opts) do
    {connection, opts} =
      opts
      |> PlaywrightEx.Channel.validate_known!(BrowserType.launch_persistent_context_opts_schema())
      |> Keyword.pop!(:connection)

    playwright_init = Connection.initializer!(connection, "Playwright")
    type_id = playwright_init |> Map.fetch!(type) |> Map.fetch!(:guid)
    BrowserType.launch_persistent_context(type_id, opts ++ [connection: connection])
  end

  @doc """
  Connects to an existing browser instance using the Chrome DevTools Protocol endpoint.

  ## Options

  #{NimbleOptions.docs(BrowserType.connect_over_cdp_opts_schema())}
  """
  @spec connect_over_cdp(atom(), [BrowserType.connect_over_cdp_opt() | unknown_opt()]) ::
          {:ok, %{guid: guid()}} | {:error, any()}
  def connect_over_cdp(type, opts) do
    {connection, opts} =
      opts
      |> PlaywrightEx.Channel.validate_known!(BrowserType.connect_over_cdp_opts_schema())
      |> Keyword.pop!(:connection)

    playwright_init = Connection.initializer!(connection, "Playwright")
    type_id = playwright_init |> Map.fetch!(type) |> Map.fetch!(:guid)
    BrowserType.connect_over_cdp(type_id, opts ++ [connection: connection])
  end

  subscribe_schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      pid: [
        type: :pid,
        doc: "The process to send messages to. Defaults to `self()`."
      ]
    )

  @doc """
  Subscribe to playwright responses concerning a resource, identified by its `guid`.
  Messages in the format `{:playwright_msg, %{} = msg}` will be sent to `pid`.

  ## Options
  #{NimbleOptions.docs(subscribe_schema)}
  """
  @subscribe_schema subscribe_schema
  @type subscribe_opt :: unquote(NimbleOptions.option_typespec(subscribe_schema))
  @spec subscribe(guid(), [subscribe_opt()]) :: :ok
  def subscribe(guid, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @subscribe_schema)
    pid = Keyword.get(opts, :pid, self())
    Connection.subscribe(opts[:connection], pid, guid)
  end

  @doc """
  Unsubscribe from playwright responses concerning a resource, identified by its `guid`.

  ## Options
  #{NimbleOptions.docs(subscribe_schema)}
  """
  @spec unsubscribe(guid(), [subscribe_opt()]) :: :ok
  def unsubscribe(guid, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @subscribe_schema)
    pid = Keyword.get(opts, :pid, self())
    Connection.unsubscribe(opts[:connection], pid, guid)
  end

  send_schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Send message to playwright.

  Don't use this! Prefer `Channels` functions.
  If a function is missing, consider [opening a PR](https://github.com/ftes/playwright_ex/pulls) to add it.

  ## Options
  #{NimbleOptions.docs(send_schema)}
  """
  @send_schema send_schema
  @type send_opt :: unquote(NimbleOptions.option_typespec(send_schema))
  @spec send(%{guid: guid(), method: atom()}, [send_opt()]) :: %{result: map()} | %{error: map()}
  def send(msg, opts) do
    opts = NimbleOptions.validate!(opts, @send_schema)
    Connection.send(opts[:connection], msg, opts[:timeout])
  end
end
