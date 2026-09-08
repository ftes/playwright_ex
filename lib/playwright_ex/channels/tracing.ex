defmodule PlaywrightEx.Tracing do
  @moduledoc """
  Interact with a Playwright `Tracing`.

  There is no official documentation, since this is considered Playwright internal.

  Reference: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/tracing.ts
  """

  alias PlaywrightEx.Artifact
  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      name: [
        type: :string,
        doc: "Trace name used for the generated trace files."
      ],
      screenshots: [
        type: :boolean,
        doc: "Whether to capture a screencast during tracing."
      ],
      snapshots: [
        type: {:or, [:boolean, :map, :keyword_list]},
        type_spec:
          quote(
            do:
              boolean()
              | %{
                  optional(:dom) => boolean(),
                  optional(:aria) => boolean(),
                  optional(:screen) => boolean()
                }
              | keyword(boolean())
          ),
        type_doc: "`boolean | %{optional(:dom | :aria | :screen) => boolean} | keyword(boolean)`",
        doc:
          "Snapshot capture settings. A boolean controls DOM snapshots; a map or keyword list can configure `:dom`, `:aria`, and `:screen` separately."
      ]
    )

  @doc """
  Starts tracing.

  Reference: https://playwright.dev/docs/api/class-tracing#tracing-start

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type start_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec tracing_start(PlaywrightEx.guid(), [start_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def tracing_start(tracing_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    params = tracing_start_params(opts)

    connection
    |> Connection.send(%{guid: tracing_id, method: :tracing_start, params: params}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  defp tracing_start_params(opts) do
    {snapshots, opts} = Keyword.pop(opts, :snapshots)
    {screenshots, opts} = Keyword.pop(opts, :screenshots)

    opts
    |> maybe_put(:screencast, screenshots)
    |> put_snapshot_options(snapshots)
    |> Map.new()
  end

  defp put_snapshot_options(opts, snapshots) when is_boolean(snapshots) do
    Keyword.put(opts, :snapshot_dom, snapshots)
  end

  defp put_snapshot_options(opts, snapshots) when is_map(snapshots) or is_list(snapshots) do
    Enum.reduce(snapshots, opts, fn
      {:dom, value}, acc when is_boolean(value) -> Keyword.put(acc, :snapshot_dom, value)
      {:aria, value}, acc when is_boolean(value) -> Keyword.put(acc, :snapshot_aria, value)
      {:screen, value}, acc when is_boolean(value) -> Keyword.put(acc, :snapshot_screen, value)
      option, _acc -> raise ArgumentError, "invalid tracing snapshot option: #{inspect(option)}"
    end)
  end

  defp put_snapshot_options(opts, nil), do: opts

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      title: [
        type: :string,
        doc: "Trace name to be shown in the Trace Viewer."
      ]
    )

  @doc """
  Starts a new chunk in the tracing.

  Reference: https://playwright.dev/docs/api/class-tracing#tracing-start-chunk

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type start_chunk_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec tracing_start_chunk(PlaywrightEx.guid(), [start_chunk_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def tracing_start_chunk(tracing_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: tracing_id, method: :tracing_start_chunk, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Stops tracing.

  Reference: https://playwright.dev/docs/api/class-tracing#tracing-stop

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type stop_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec tracing_stop(PlaywrightEx.guid(), [stop_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def tracing_stop(tracing_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: tracing_id, method: :tracing_stop, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      mode: [
        type: {:in, [:archive, :discard, :entries]},
        doc: "Mode for stopping the chunk",
        default: :archive
      ]
    )

  @doc """
  Stops a chunk of tracing.

  Reference: https://playwright.dev/docs/api/class-tracing#tracing-stop-chunk

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type stop_chunk_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec tracing_stop_chunk(PlaywrightEx.guid(), [stop_chunk_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid(), absolute_path: Path.t()} | [map()] | nil} | {:error, any()}
  def tracing_stop_chunk(tracing_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    mode = Keyword.fetch!(opts, :mode)

    with {:ok, result} <-
           connection
           |> Connection.send(%{guid: tracing_id, method: :tracing_stop_chunk, params: Map.new(opts)}, timeout)
           |> ChannelResponse.unwrap(& &1) do
      handle_stop_chunk_result(mode, result, connection, timeout)
    end
  end

  defp handle_stop_chunk_result(:discard, _result, _connection, _timeout), do: {:ok, nil}
  defp handle_stop_chunk_result(:entries, result, _connection, _timeout), do: {:ok, Map.get(result, :entries, [])}
  defp handle_stop_chunk_result(:archive, %{artifact: nil}, _connection, _timeout), do: {:ok, nil}

  defp handle_stop_chunk_result(:archive, result, _connection, _timeout) when not is_map_key(result, :artifact),
    do: {:ok, nil}

  defp handle_stop_chunk_result(:archive, %{artifact: artifact}, connection, timeout) do
    artifact = Map.merge(artifact, Connection.initializer!(connection, artifact.guid))
    maybe_download_artifact(connection, artifact, timeout)
  end

  defp maybe_download_artifact(connection, artifact, timeout) do
    if Connection.remote?(connection) do
      download_artifact(artifact, connection, timeout)
    else
      {:ok, artifact}
    end
  end

  defp download_artifact(artifact, connection, timeout) do
    path = Path.join(System.tmp_dir!(), "playwright-trace-#{System.unique_integer([:positive])}.zip")

    with :ok <- Artifact.save_as(artifact.guid, path, connection: connection, timeout: timeout),
         {:ok, _} <- Artifact.delete(artifact.guid, connection: connection, timeout: timeout) do
      {:ok, %{artifact | absolute_path: path}}
    end
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      name: [
        type: :string,
        required: true,
        doc: "Name of the group to appear in trace viewer"
      ],
      location: [
        type: :non_empty_keyword_list,
        required: false,
        keys: [
          file: [
            type: :string,
            required: true,
            doc: "File path for the source location"
          ],
          line: [
            type: :integer,
            required: true,
            doc: "Line number in the source file"
          ],
          column: [
            type: :integer,
            required: false,
            doc: "Column number in the source file"
          ]
        ],
        doc: "Source location metadata for the trace group"
      ]
    )

  @doc group: :composed
  @doc """
  Wraps a function call in a named trace group.

  Reference: https://playwright.dev/docs/api/class-tracing#tracing-group

  Automatically starts a trace group before executing the function and ends it after,
  ensuring proper cleanup even if the function raises an exception.

  ## Options
  #{NimbleOptions.docs(schema)}

  ## Examples
      Tracing.group(browser_context.tracing.guid, [name: "Login Flow"], fn ->
        Page.fill(page_id, "#email", "user@example.com")
        Page.fill(page_id, "#password", "secret")
        Page.click(page_id, "button[type=submit]")
      end)

      # Custom location for trace viewer navigation
      Tracing.group(browser_context.tracing.guid,
        [name: "Login Flow", location: [file: "/absolute/path/to/test.exs", line: 42]],
        fn ->
          # assertion logic
        end)

      # Groups can be nested
      Tracing.group(browser_context.tracing.guid, [name: "User Workflow"], fn ->
        Tracing.group(browser_context.tracing.guid, [name: "Login"], fn ->
          # login actions
        end)

        Tracing.group(browser_context.tracing.guid, [name: "Dashboard"], fn ->
          # dashboard actions
        end)
      end)

  """
  @schema schema
  @type group_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec group(PlaywrightEx.guid(), [group_opt() | PlaywrightEx.unknown_opt()], (-> result)) :: result
        when result: any()
  def group(tracing_id, opts, fun) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    # Convert keyword list to map, and convert nested location keyword list to map if present
    params =
      Map.new(opts, fn {k, v} -> if k == :location, do: {k, Map.new(v)}, else: {k, v} end)

    {:ok, _} =
      connection
      |> Connection.send(%{guid: tracing_id, method: :tracing_group, params: params}, timeout)
      |> ChannelResponse.unwrap(& &1)

    try do
      fun.()
    after
      connection
      |> Connection.send(%{guid: tracing_id, method: :tracing_group_end, params: %{}}, timeout)
      |> ChannelResponse.unwrap(& &1)
    end
  end
end
