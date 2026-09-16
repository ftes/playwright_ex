defmodule PlaywrightEx.ElementHandle do
  @moduledoc """
  Interact with a Playwright `ElementHandle`.

  There is no official channel documentation, since this is considered
  Playwright internal.

  Reference: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/elementHandle.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection
  alias PlaywrightEx.FileInput
  alias PlaywrightEx.Serialization

  schema =
    NimbleOptions.new!(
      [
        connection: PlaywrightEx.Channel.connection_opt(),
        timeout: PlaywrightEx.Channel.timeout_opt()
      ] ++ FileInput.selection_schema()
    )

  @doc """
  Sets the files on the input element represented by this handle.

  Pass either `:local_paths` or `:payloads`. An empty list clears the selected
  files. This operation can be used with the element handle carried by a
  subscribed page's `:file_chooser` event.

  Reference: https://playwright.dev/docs/api/class-filechooser#file-chooser-set-files

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type set_input_files_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec set_input_files(PlaywrightEx.guid(), [set_input_files_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def set_input_files(element_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    params = opts |> FileInput.prepare(connection) |> Map.new()

    connection
    |> Connection.send(%{guid: element_id, method: :set_input_files, params: params}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      expression: [type: :string, required: true],
      is_function: [type: :boolean, default: false],
      arg: [type: :any, default: nil]
    )

  @doc """
  Evaluates an expression on this element. A function receives the element and
  the optional `:arg`. Returns the deserialized value or the original protocol error.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type evaluate_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec evaluate(PlaywrightEx.guid(), [evaluate_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def evaluate(element_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    params = opts |> Map.new() |> Map.update!(:arg, &Serialization.serialize_arg/1)

    connection
    |> Connection.send(%{guid: element_id, method: :evaluate_expression, params: params}, timeout)
    |> ChannelResponse.unwrap(&Serialization.deserialize_arg(&1.value))
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Releases this handle's browser reference. Already-closed targets are treated as
  successfully disposed; other errors are preserved.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type dispose_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec dispose(PlaywrightEx.guid(), [dispose_opt()]) :: {:ok, any()} | {:error, any()}
  def dispose(element_id, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @schema)
    connection = Keyword.fetch!(opts, :connection)
    timeout = Keyword.fetch!(opts, :timeout)

    connection
    |> Connection.send(%{guid: element_id, method: :dispose, params: %{}}, timeout)
    |> ChannelResponse.unwrap(& &1)
    |> disposed_result()
  end

  defp disposed_result({:error, %{error: %{name: "TargetClosedError"}}}), do: {:ok, %{}}
  defp disposed_result(result), do: result
end
