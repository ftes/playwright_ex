defmodule Playwright.Transport.Protocol.SetInputFilesFiles do
  @moduledoc "upstream: Transport/Protocol/SetInputFilesFiles.cs"
  defstruct [:payloads, :local_paths, :local_directory, :streams, :directory_stream]
end

defmodule Playwright.Helpers.SetInputFilesHelpers do
  @moduledoc "upstream: Helpers/SetInputFilesHelpers.cs"
  alias Playwright.PlaywrightException
  alias Playwright.Transport.Connection
  alias Playwright.Transport.Protocol.SetInputFilesFiles

  @size_limit_in_bytes 50 * 1024 * 1024

  # upstream: Helpers/SetInputFilesHelpers.cs:39
  defp resolve_paths_and_directory_for_input_files(items) do
    {local_paths, local_directory} =
      Enum.reduce(items, {nil, nil}, fn item, {local_paths, local_directory} ->
        if File.dir?(item) do
          if local_directory != nil do
            raise PlaywrightException.new("Multiple directories are not supported")
          end
          {local_paths, Path.expand(item)}
        else
          local_paths = local_paths || []
          {local_paths ++ [Path.expand(item)], local_directory}
        end
      end)

    if local_paths != nil and local_paths != [] and local_directory != nil do
      raise PlaywrightException.new("File paths must be all files or a single directory")
    end

    {local_paths, local_directory}
  end

  # upstream: Helpers/SetInputFilesHelpers.cs:79
  def convert_input_files_async(files, context) do
    if Enum.empty?(files) do
      %SetInputFilesFiles{payloads: []}
    else
      {local_paths, local_directory} = resolve_paths_and_directory_for_input_files(files)

      if Connection.is_remote(context.connection) do
        # skipped: remote connections (createTempFiles + WritableStream upload)
        raise PlaywrightException.new("Remote SetInputFiles is not ported")
      end

      %SetInputFilesFiles{local_paths: local_paths, local_directory: local_directory}
    end
  end

  # upstream: Helpers/SetInputFilesHelpers.cs:128
  def convert_input_files(files) do
    file_payload_exceeds_size_limit = Enum.sum(Enum.map(files, &byte_size(&1.buffer))) > @size_limit_in_bytes

    if file_payload_exceeds_size_limit do
      raise PlaywrightException.new("Cannot set buffer larger than 50Mb, please write it to a file and pass its path instead.")
    end

    %SetInputFilesFiles{
      payloads:
        Enum.map(files, fn f ->
          %{"name" => f.name, "buffer" => Base.encode64(f.buffer), "mimeType" => f.mime_type}
        end)
    }
  end
end
