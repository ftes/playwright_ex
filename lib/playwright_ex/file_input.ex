defmodule PlaywrightEx.FileInput do
  @moduledoc false

  alias PlaywrightEx.Connection
  alias PlaywrightEx.FilePayload

  def selection_schema do
    [
      local_paths: [
        type: {:or, [:string, {:list, :string}]},
        doc:
          "A file path or list of file paths. Relative paths are resolved relative to the current working directory. An empty list clears the selected files."
      ],
      payloads: [
        type: {:or, [{:struct, FilePayload}, {:list, {:struct, FilePayload}}]},
        type_spec: quote(do: FilePayload.t() | [FilePayload.t()]),
        type_doc: "`PlaywrightEx.FilePayload.t() | [PlaywrightEx.FilePayload.t()]`",
        doc: "An in-memory file payload or list of payloads. An empty list clears the selected files."
      ]
    ]
  end

  def prepare(opts, connection) do
    case {Keyword.fetch(opts, :local_paths), Keyword.fetch(opts, :payloads)} do
      {{:ok, _paths}, {:ok, _payloads}} ->
        raise ArgumentError, "expected either :local_paths or :payloads, got both"

      {:error, :error} ->
        raise ArgumentError, "expected either :local_paths or :payloads"

      {{:ok, paths}, :error} ->
        prepare_local_paths(opts, List.wrap(paths), connection)

      {:error, {:ok, payloads}} ->
        prepare_payloads(opts, List.wrap(payloads))
    end
  end

  defp prepare_local_paths(opts, [], _connection) do
    opts |> Keyword.delete(:local_paths) |> Keyword.put(:payloads, [])
  end

  defp prepare_local_paths(opts, paths, connection) do
    if Connection.remote?(connection) do
      payloads =
        Enum.map(paths, fn path ->
          %FilePayload{name: Path.basename(path), buffer: File.read!(Path.expand(path))}
        end)

      opts |> Keyword.delete(:local_paths) |> put_serialized_payloads(payloads)
    else
      Keyword.put(opts, :local_paths, paths)
    end
  end

  defp prepare_payloads(opts, payloads) do
    opts |> Keyword.delete(:payloads) |> put_serialized_payloads(payloads)
  end

  defp put_serialized_payloads(opts, payloads) do
    Keyword.put(opts, :payloads, Enum.map(payloads, &serialize_payload/1))
  end

  defp serialize_payload(%FilePayload{name: name, buffer: buffer, mime_type: mime_type} = payload)
       when is_binary(name) and is_binary(buffer) and (is_binary(mime_type) or is_nil(mime_type)) do
    %{name: payload.name, mime_type: payload.mime_type, buffer: Base.encode64(payload.buffer)}
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp serialize_payload(%FilePayload{} = payload) do
    raise ArgumentError,
          "expected a PlaywrightEx.FilePayload with binary :name and :buffer and an optional binary :mime_type, " <>
            "got: #{inspect(payload)}"
  end
end
