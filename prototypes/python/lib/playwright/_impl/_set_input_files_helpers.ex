# upstream: playwright/_impl/_set_input_files_helpers.py (subset)
defmodule Playwright.Impl.SetInputFilesHelpers do
  alias Playwright.Impl.Errors.Error

  @size_limit_in_bytes 50 * 1024 * 1024

  # upstream: _set_input_files_helpers.py:59
  def convert_input_files(files, context) do
    items = if is_list(files), do: files, else: [files]

    if Enum.any?(items, &is_binary/1) do
      if not Enum.all?(items, &is_binary/1),
        do: raise(Error.new("File paths cannot be mixed with buffers"))

      {local_paths, local_directory} = resolve_paths_and_directory_for_input_files(items)

      if context[:_channel][:_connection][:is_remote] do
        # (remote: createTempFiles + WritableStream copy omitted in prototype)
        raise Error.new("remote set_input_files not ported")
      end

      %{"localPaths" => local_paths, "localDirectory" => local_directory}
    else
      file_payload_exceeds_size_limit =
        Enum.sum(for f <- items, do: byte_size(f["buffer"] || "")) > @size_limit_in_bytes

      if file_payload_exceeds_size_limit,
        do:
          raise(
            Error.new(
              "Cannot set buffer larger than 50Mb, please write it to a file and pass its path instead."
            )
          )

      %{
        "payloads" =>
          for item <- items do
            %{
              "name" => item["name"],
              "mimeType" => item["mimeType"],
              "buffer" => Base.encode64(item["buffer"])
            }
          end
      }
    end
  end

  # upstream: _set_input_files_helpers.py:142
  def resolve_paths_and_directory_for_input_files(items) do
    {local_paths, local_directory} =
      Enum.reduce(items, {nil, nil}, fn item, {local_paths, local_directory} ->
        # Raises File.Error if doesn't exist
        item_stat = File.stat!(item)

        if item_stat.type == :directory do
          if local_directory, do: raise(Error.new("Multiple directories are not supported"))
          {local_paths, Path.expand(item)}
        else
          {(local_paths || []) ++ [Path.expand(item)], local_directory}
        end
      end)

    if local_paths && local_directory,
      do: raise(Error.new("File paths must be all files or a single directory"))

    {local_paths, local_directory}
  end
end
