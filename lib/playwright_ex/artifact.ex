defmodule PlaywrightEx.Artifact do
  @moduledoc """
  Interact with a Playwright `Artifact`.

  Artifacts are Playwright-owned files produced by operations such as tracing or
  downloads. Local Playwright connections expose a finished artifact path
  directly, while remote connections require streaming the artifact bytes through
  the protocol.
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @schema schema
  @type opt :: unquote(NimbleOptions.option_typespec(schema))

  @doc """
  Saves an artifact to `path`.

  For local Playwright connections this copies the finished artifact file. For
  remote Playwright connections this streams the artifact through the Playwright
  protocol.
  """
  @spec save_as(PlaywrightEx.guid(), Path.t(), [opt() | PlaywrightEx.unknown_opt()]) :: :ok | {:error, any()}
  def save_as(artifact_guid, path, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, _opts} = Keyword.pop!(opts, :timeout)

    if Connection.remote?(connection) do
      save_as_stream(connection, artifact_guid, timeout, path)
    else
      copy_from_finished_path(artifact_guid, connection, timeout, path)
    end
  end

  @doc """
  Deletes an artifact from Playwright.
  """
  @spec delete(PlaywrightEx.guid(), [opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def delete(artifact_guid, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, _opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: artifact_guid, method: :delete, params: %{}}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  defp copy_from_finished_path(artifact_guid, connection, timeout, path) do
    with {:ok, source_path} <- path_after_finished(artifact_guid, connection: connection, timeout: timeout) do
      File.cp(source_path, path)
    end
  end

  defp path_after_finished(artifact_guid, opts) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, _opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: artifact_guid, method: :path_after_finished, params: %{}}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  defp save_as_stream(connection, artifact_guid, timeout, path) do
    with {:ok, %{stream: %{guid: stream_guid}}} <-
           connection
           |> Connection.send(%{guid: artifact_guid, method: :save_as_stream, params: %{}}, timeout)
           |> ChannelResponse.unwrap(& &1),
         :ok <- stream_to_file(connection, stream_guid, timeout, path),
         {:ok, _} <- close_stream(connection, stream_guid, timeout) do
      :ok
    end
  end

  defp stream_to_file(connection, stream_guid, timeout, path) do
    File.open!(path, [:write, :binary], fn file ->
      read_stream_to_file(connection, stream_guid, timeout, file)
    end)
  end

  defp read_stream_to_file(connection, stream_guid, timeout, file) do
    case connection
         |> Connection.send(%{guid: stream_guid, method: :read, params: %{size: 1024 * 1024}}, timeout)
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
end
