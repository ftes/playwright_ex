# upstream: packages/playwright-core/src/client/elementHandle.ts (module-level helpers only;
# the ElementHandle class itself is not ported and is created as a DummyChannelOwner)
defmodule PlaywrightJS.Client.ElementHandle do
  alias PlaywrightJS.Client.{BrowserContext, ChannelOwner, Connection, TimeoutSettings, WritableStream}
  import PlaywrightJS.Runtime.Heap

  @file_upload_size_limit 50 * 1024 * 1024

  # upstream: elementHandle.ts:241
  def convert_select_option_values(values) do
    values = if values == nil or is_list(values), do: values, else: [values]

    cond do
      values == nil ->
        %{}

      values == [] ->
        %{}

      true ->
        for {v, i} <- Enum.with_index(values), do: if(v == nil, do: raise("options[#{i}]: expected object, got null"))

        cond do
          is_struct(hd(values), Connection.DummyChannelOwner) -> %{elements: values}
          is_binary(hd(values)) -> %{options: Enum.map(values, fn value_or_label -> %{valueOrLabel: value_or_label} end)}
          true -> %{options: values}
        end
    end
  end

  # upstream: elementHandle.ts:259
  defp file_payload_exceeds_size_limit(payloads) do
    Enum.reduce(payloads, 0, fn item, size -> size + if(item[:buffer], do: byte_size(item.buffer), else: 0) end) >= @file_upload_size_limit
  end

  # upstream: elementHandle.ts:263
  defp resolve_paths_and_directory_for_input_files(items) do
    {local_paths, local_directory} =
      Enum.reduce(items, {nil, nil}, fn item, {local_paths, local_directory} ->
        stat = File.stat!(item)

        if stat.type == :directory do
          if local_directory, do: raise("Multiple directories are not supported")
          {local_paths, Path.expand(item)}
        else
          {(local_paths || []) ++ [Path.expand(item)], local_directory}
        end
      end)

    if local_paths && local_paths != [] && local_directory, do: raise("File paths must be all files or a single directory")
    {local_paths, local_directory}
  end

  # upstream: elementHandle.ts:282
  def convert_input_files(files, context) do
    items = List.wrap(files)

    if Enum.any?(items, &is_binary/1) do
      if !Enum.all?(items, &is_binary/1), do: raise("File paths cannot be mixed with buffers")

      {local_paths, local_directory} = resolve_paths_and_directory_for_input_files(items)

      if Connection.is_remote(get(context, :_connection)) do
        files =
          if local_directory,
            do: Path.wildcard(Path.join(local_directory, "**/*"), match_dot: true) |> Enum.filter(&File.regular?/1),
            else: local_paths

        %{writableStreams: writable_streams} =
          result =
          BrowserContext._wrap_api_call(
            context,
            fn _ ->
              ChannelOwner.channel_call(
                context,
                :createTempFiles,
                %{
                  rootDirName: if(local_directory, do: Path.basename(local_directory)),
                  items:
                    Enum.map(files, fn file ->
                      last_modified_ms = File.stat!(file, time: :posix).mtime * 1000
                      %{name: if(local_directory, do: Path.relative_to(file, local_directory), else: Path.basename(file)), lastModifiedMs: last_modified_ms}
                    end)
                },
                TimeoutSettings.k_no_timeout()
              )
            end,
            %{internal: true}
          )

        root_dir = result[:rootDir]

        for {file, i} <- Enum.with_index(files) do
          writable = WritableStream.from(Enum.at(writable_streams, i))
          # await stream.promises.pipeline(fs.createReadStream(files[i]), writable.stream());
          WritableStream.stream(writable, File.stream!(file, 1024 * 1024))
        end

        %{directoryStream: root_dir, streams: if(local_directory, do: nil, else: writable_streams)}
      else
        %{localPaths: local_paths, localDirectory: local_directory}
      end
    else
      payloads = Enum.map(items, fn payload -> Map.update(payload, :buffer, nil, &Base.encode64/1) end)

      if file_payload_exceeds_size_limit(items),
        do: raise("Cannot set buffer larger than 50Mb, please write it to a file and pass its path instead.")

      %{payloads: payloads}
    end
  end
end
