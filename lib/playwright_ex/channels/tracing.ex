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
end
