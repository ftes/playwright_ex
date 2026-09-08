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
      args: [
        type: {:list, :string},
        doc: "Additional command-line arguments passed to the browser."
      ],
      executable_path: [
        type: :string,
        doc: "Path to a browser executable to run instead of the bundled one."
      ],
      ignore_all_default_args: [
        type: :boolean,
        doc: "Whether to omit all Playwright default browser arguments."
      ],
      ignore_default_args: [
        type: {:list, :string},
        doc: "Specific Playwright default browser arguments to omit."
      ],
      handle_sigint: [type: :boolean, doc: "Whether Playwright handles SIGINT."],
      handle_sigterm: [type: :boolean, doc: "Whether Playwright handles SIGTERM."],
      handle_sighup: [type: :boolean, doc: "Whether Playwright handles SIGHUP."],
      env: [
        type: {:or, [{:map, {:or, [:atom, :string]}, :any}, {:list, :map}]},
        doc: "Environment variables as a map or Playwright name/value entries."
      ],
      headless: [
        type: :boolean,
        doc: "Whether to run browser in headless mode."
      ],
      proxy: [type: :map, doc: "Proxy settings for the browser process."],
      downloads_path: [type: :string, doc: "Directory in which to place downloads."],
      traces_dir: [type: :string, doc: "Directory in which to place tracing data."],
      artifacts_dir: [type: :string, doc: "Directory in which to place browser artifacts."],
      chromium_sandbox: [type: :boolean, doc: "Whether Chromium sandboxing is enabled."],
      firefox_user_prefs: [
        type: {:map, {:or, [:atom, :string]}, :any},
        doc: "Firefox preferences, preserved as an opaque JSON object."
      ],
      cdp_port: [type: :non_neg_integer, doc: "Chrome DevTools Protocol port."],
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
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    opts = prepare_launch_opts(opts)

    connection
    |> Connection.send(%{guid: type_id, method: :launch, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap_create(:browser, connection)
  end

  defp prepare_launch_opts(opts) do
    case Keyword.fetch(opts, :env) do
      {:ok, env} when is_map(env) ->
        Keyword.put(opts, :env, Enum.map(env, fn {name, value} -> %{name: to_string(name), value: to_string(value)} end))

      _ ->
        opts
    end
  end

  @doc false
  def launch_opts_schema, do: @schema
end
