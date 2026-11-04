defmodule Playwright.Impl.Utils do
  # upstream: Utils.java:43
  alias Playwright.PlaywrightException
  alias Playwright.Impl.Serialization

  # upstream: Utils.java:44
  # Java copies same-named fields reflectively between Options classes; Elixir: struct/2 drops unknown keys.
  def convert_type(nil, _t), do: nil
  def convert_type(f, _t) when is_atom(f), do: f

  def convert_type(f, t) do
    for {key, value} <- Map.from_struct(f), value != nil, reduce: struct(t) do
      result -> if Map.has_key?(result, key), do: Map.put(result, key, value), else: result
    end
  end

  # upstream: Utils.java:107
  def add_file_path_upload_params(items, params, context) do
    {local_directory, local_paths} = resolve_paths_and_directory_for_input_files(items)

    cond do
      items == [] ->
        # FIXME: shouldBeAbleToResetSelectedFilesWithEmptyFileList tesst hangs in Chromium if we pass empty paths list.
        Map.put(params, "payloads", [])

      context.connection.is_remote ->
        raise PlaywrightException, message: "not ported: remote file upload"

      true ->
        params =
          if local_paths != [],
            do: Map.put(params, "localPaths", Serialization.to_json_array(local_paths)),
            else: params

        if local_directory != nil, do: Map.put(params, "localDirectory", local_directory), else: params
    end
  end

  # upstream: Utils.java:135
  # Java fills the `outLocalPaths` out-parameter; Elixir returns {localDirectory, localPaths}.
  defp resolve_paths_and_directory_for_input_files(items) do
    {local_directory, out_local_paths} =
      Enum.reduce(items, {nil, []}, fn item, {local_directory, out_local_paths} ->
        if File.dir?(item) do
          if local_directory != nil, do: raise(PlaywrightException, message: "Multiple directories are not supported")
          {real_path!(item), out_local_paths}
        else
          {local_directory, out_local_paths ++ [real_path!(item)]}
        end
      end)

    if out_local_paths != [] and local_directory != nil,
      do: raise(PlaywrightException, message: "File paths must be all files or a single directory")

    {local_directory, out_local_paths}
  end

  defp real_path!(path) do
    if !File.exists?(path), do: raise(PlaywrightException, message: "Cannot get absolute file path")
    Path.expand(path)
  end

  # upstream: Utils.java:271
  def is_safe_close_error(%{message: message}), do: is_safe_close_error(message)

  # upstream: Utils.java:275
  def is_safe_close_error(error) when is_binary(error) do
    String.contains?(error, "Browser has been closed") or
      String.contains?(error, "Target page, context or browser has been closed")
  end

  # upstream: Utils.java:279
  def create_guid do
    for _ <- 1..4, into: "", do: Integer.to_string(:rand.uniform(0xFFFFFFFF), 16) |> String.downcase()
  end

  # upstream: Utils.java:307
  def to_js_regex_flags(pattern) do
    opts = Regex.opts(pattern)
    regex_flags = ""
    # Case-insensitive search.
    regex_flags = if :caseless in opts, do: regex_flags <> "i", else: regex_flags
    # Allows . to match newline characters.
    regex_flags = if :dotall in opts, do: regex_flags <> "s", else: regex_flags
    # Multi-line search.
    regex_flags = if :multiline in opts, do: regex_flags <> "m", else: regex_flags

    if Enum.any?(opts, &(&1 not in [:caseless, :dotall, :multiline])),
      do:
        raise(PlaywrightException,
          message: "Unexpected RegEx flag, only CASE_INSENSITIVE, DOTALL and MULTILINE are supported."
        )

    regex_flags
  end
end
