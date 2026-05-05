defmodule PlaywrightEx.Download do
  @moduledoc """
  Interact with a Playwright `Download`.

  Reference: https://playwright.dev/docs/api/class-download
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Returns the path to the downloaded file.

  Only available for local (non-remote) connections.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type path_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec path(PlaywrightEx.guid(), [path_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t()} | {:error, any()}
  def path(artifact_guid, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, _opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: artifact_guid, method: :path_after_finished, params: %{}}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Streams the downloaded file to a local temp path.

  Used for remote (WebSocket) connections where the file lives on the remote
  Playwright server and must be transferred over the protocol.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type save_as_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec save_as(PlaywrightEx.guid(), [save_as_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t()} | {:error, any()}
  def save_as(artifact_guid, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, _opts} = Keyword.pop!(opts, :timeout)

    local_path = Path.join(System.tmp_dir!(), "playwright-download-#{System.unique_integer([:positive])}")

    with {:ok, %{stream: %{guid: stream_guid}}} <-
           connection
           |> Connection.send(%{guid: artifact_guid, method: :save_as_stream, params: %{}}, timeout)
           |> ChannelResponse.unwrap(& &1),
         :ok <- stream_to_file(connection, stream_guid, timeout, local_path),
         {:ok, _} <- close_stream(connection, stream_guid, timeout),
         {:ok, _} <- delete_artifact(connection, artifact_guid, timeout) do
      {:ok, local_path}
    end
  end

  defp stream_to_file(connection, stream_guid, timeout, path) do
    File.open!(path, [:write, :binary], fn file ->
      read_stream_to_file(connection, stream_guid, timeout, file)
    end)
  end

  defp read_stream_to_file(connection, stream_guid, timeout, file) do
    case connection
         |> Connection.send(%{guid: stream_guid, method: :read, params: %{size: 1_048_576}}, timeout)
         |> ChannelResponse.unwrap(& &1) do
      {:ok, %{binary: ""}} ->
        :ok

      {:ok, %{binary: chunk}} ->
        IO.binwrite(file, Base.decode64!(chunk))
        read_stream_to_file(connection, stream_guid, timeout, file)

      {:error, _} = error ->
        error
    end
  end

  defp close_stream(connection, stream_guid, timeout) do
    connection
    |> Connection.send(%{guid: stream_guid, method: :close, params: %{}}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  defp delete_artifact(connection, artifact_guid, timeout) do
    connection
    |> Connection.send(%{guid: artifact_guid, method: :delete, params: %{}}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
