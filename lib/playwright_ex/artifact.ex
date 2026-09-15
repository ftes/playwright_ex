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
  alias PlaywrightEx.Timeout

  @cleanup_timeout 1_000

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @schema schema
  @type opt :: unquote(NimbleOptions.option_typespec(schema))

  @doc """
  Saves an artifact to `path`.

  Copies locally or streams over WebSocket, preserving the source artifact.
  Creates parent directories and replaces the destination only when saving
  succeeds. Temporary files and streams are cleaned up on failure.

  The required `:timeout` covers the whole transfer. `0` times out immediately;
  `:infinity` disables the timeout. Cleanup may outlast the transfer timeout.
  Expected cleanup errors preserve the transfer result; unexpected errors propagate.
  """
  @spec save_as(PlaywrightEx.guid(), Path.t(), [opt() | PlaywrightEx.unknown_opt()]) :: :ok | {:error, any()}
  def save_as(artifact_guid, path, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, _opts} = Keyword.pop!(opts, :timeout)

    deadline = Timeout.deadline(timeout)

    with {:ok, _remaining} <- remaining(deadline),
         {:ok, transport} <- Connection.fetch_transport(connection),
         {:ok, staging_path} <- create_staging_file(path) do
      save_staged(connection, artifact_guid, deadline, staging_path, path, transport)
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

  defp save_staged(connection, artifact_guid, deadline, staging_path, path, transport) do
    result =
      if transport == PlaywrightEx.PortTransport do
        copy_from_finished_path(artifact_guid, connection, deadline, staging_path)
      else
        save_as_stream(connection, artifact_guid, deadline, staging_path)
      end

    with :ok <- result, do: File.rename(staging_path, path)
  after
    File.rm(staging_path)
  end

  defp copy_from_finished_path(artifact_guid, connection, deadline, path) do
    with {:ok, %{value: source_path}} <- request(connection, artifact_guid, :path_after_finished, %{}, deadline),
         {:ok, _remaining} <- remaining(deadline),
         :ok <- File.cp(source_path, path),
         {:ok, _remaining} <- remaining(deadline),
         do: :ok
  end

  defp save_as_stream(connection, artifact_guid, deadline, path) do
    with {:ok, %{stream: %{guid: stream_guid}}} <-
           request(connection, artifact_guid, :save_as_stream, %{}, deadline) do
      save_stream(connection, stream_guid, deadline, path)
    end
  end

  defp save_stream(connection, stream_guid, deadline, path) do
    with :ok <- stream_to_file(connection, stream_guid, deadline, path),
         {:ok, _remaining} <- remaining(deadline),
         do: :ok
  after
    request(connection, stream_guid, :close, %{}, Timeout.deadline(@cleanup_timeout))
  end

  defp stream_to_file(connection, stream_guid, deadline, path) do
    with {:ok, result} <- File.open(path, [:write, :binary], &read_stream_to_file(connection, stream_guid, deadline, &1)),
         do: result
  end

  defp read_stream_to_file(connection, stream_guid, deadline, file) do
    case request(connection, stream_guid, :read, %{size: 1024 * 1024}, deadline) do
      {:ok, %{binary: ""}} ->
        :ok

      {:ok, %{binary: chunk}} ->
        with :ok <- IO.binwrite(file, Base.decode64!(chunk)),
             do: read_stream_to_file(connection, stream_guid, deadline, file)

      {:error, _} = error ->
        error
    end
  end

  defp request(connection, guid, method, params, deadline) do
    with {:ok, timeout} <- remaining(deadline) do
      connection
      |> Connection.send(%{guid: guid, method: method, params: params}, timeout)
      |> ChannelResponse.unwrap(& &1)
    end
  end

  defp create_staging_file(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)), do: open_staging_file(path)
  end

  defp open_staging_file(path) do
    staging_path = staging_path(path)

    case File.open(staging_path, [:write, :binary, :exclusive]) do
      {:ok, file} ->
        File.close(file)
        {:ok, staging_path}

      {:error, :eexist} ->
        open_staging_file(path)

      {:error, _} = error ->
        error
    end
  end

  defp staging_path(path) do
    candidate = Path.join(Path.dirname(path), ".playwright-artifact-#{System.unique_integer([:positive])}")
    if Path.expand(candidate) == Path.expand(path), do: staging_path(path), else: candidate
  end

  defp remaining(deadline) do
    case Timeout.remaining(deadline) do
      0 -> {:error, %{reason: :timeout, message: "Artifact transfer timeout exceeded"}}
      timeout -> {:ok, timeout}
    end
  end
end
