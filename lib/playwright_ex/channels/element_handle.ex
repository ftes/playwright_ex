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
end
