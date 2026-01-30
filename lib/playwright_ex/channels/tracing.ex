defmodule PlaywrightEx.Tracing do
  @moduledoc """
  Interact with a Playwright `Tracing`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/tracing.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      title: [
        type: :string,
        doc: "Trace name to be shown in the Trace Viewer."
      ],
      screenshots: [
        type: :boolean,
        doc: "Whether to capture screenshots during tracing"
      ],
      snapshots: [
        type: :boolean,
        doc: "Captures DOM snapshots and records network activity"
      ],
      sources: [
        type: :boolean,
        doc: "Whether to include source files for trace actions"
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
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: tracing_id, method: :tracing_start, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
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
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: tracing_id, method: :tracing_start_chunk, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(timeout: PlaywrightEx.Channel.timeout_opt())

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
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: tracing_id, method: :tracing_stop, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      mode: [
        type: :atom,
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
          {:ok, %{guid: PlaywrightEx.guid(), absolute_path: Path.t()}} | {:error, any()}
  def tracing_stop_chunk(tracing_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: tracing_id, method: :tracing_stop_chunk, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap_create(:artifact)
  end

  schema =
    NimbleOptions.new!(
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
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    # Convert keyword list to map, and convert nested location keyword list to map if present
    params =
      Map.new(opts, fn {k, v} -> if k == :location, do: {k, Map.new(v)}, else: {k, v} end)

    {:ok, _} =
      %{guid: tracing_id, method: :tracing_group, params: params}
      |> Connection.send(timeout)
      |> ChannelResponse.unwrap(& &1)

    try do
      fun.()
    after
      %{guid: tracing_id, method: :tracing_group_end, params: %{}}
      |> Connection.send(timeout)
      |> ChannelResponse.unwrap(& &1)
    end
  end
end
