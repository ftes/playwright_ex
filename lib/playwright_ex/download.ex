defmodule PlaywrightEx.Download do
  @moduledoc """
  A browser download's metadata and underlying artifact.

  Obtain a handle with `PlaywrightEx.Page.await_download/1` or `from_event/2`.
  The browser provides `suggested_filename` and `url` when downloading starts.

  `save_as/3` waits for completion and preserves the source artifact. Closing
  the browser context deletes the source; saved copies belong to the caller.
  """

  alias PlaywrightEx.Artifact

  @enforce_keys [:connection, :page_id, :artifact_guid, :suggested_filename, :url]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          connection: GenServer.name(),
          page_id: PlaywrightEx.guid(),
          artifact_guid: PlaywrightEx.guid(),
          suggested_filename: String.t(),
          url: String.t()
        }

  schema = NimbleOptions.new!(connection: PlaywrightEx.Channel.connection_opt())
  @event_schema schema
  @type event_opt :: unquote(NimbleOptions.option_typespec(schema))

  @doc """
  Builds a download handle from a raw `:download` event without reading its file.

  Pass the recorder's connection when using a non-default connection.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @spec from_event(map(), [event_opt()]) :: t()
  def from_event(event, opts \\ [])

  def from_event(
        %{
          guid: page_id,
          method: :download,
          params: %{artifact: %{guid: artifact_guid}, suggested_filename: filename, url: url}
        },
        opts
      ) do
    opts = NimbleOptions.validate!(opts, @event_schema)

    %__MODULE__{
      connection: opts[:connection],
      page_id: page_id,
      artifact_guid: artifact_guid,
      suggested_filename: filename,
      url: url
    }
  end

  schema = NimbleOptions.new!(timeout: PlaywrightEx.Channel.timeout_opt())
  @schema schema
  @type opt :: unquote(NimbleOptions.option_typespec(schema))

  @doc """
  Saves the completed download to `path`, preserving its source artifact.

  Uses the handle's connection and applies the timeout to the whole transfer.
  The caller owns the saved file. See `PlaywrightEx.Artifact.save_as/3` for details.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @spec save_as(t(), Path.t(), [opt() | PlaywrightEx.unknown_opt()]) :: :ok | {:error, any()}
  def save_as(%__MODULE__{} = download, path, opts \\ []) do
    Artifact.save_as(download.artifact_guid, path, artifact_opts(download, opts))
  end

  @doc """
  Explicitly deletes the source download artifact. Saved copies are unaffected.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @spec delete(t(), [opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def delete(%__MODULE__{} = download, opts \\ []) do
    Artifact.delete(download.artifact_guid, artifact_opts(download, opts))
  end

  defp artifact_opts(download, opts) do
    opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.put(:connection, download.connection)
  end
end
