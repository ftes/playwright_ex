defmodule PlaywrightEx.Runtime.Node do
  @moduledoc """
  Runtime support (not ported from upstream): the Node.js built-ins the client uses, where
  Elixir's differ (`path.resolve`, the errors of `fs`).
  """

  defmodule SystemError do
    @moduledoc """
    A Node.js system error of an `fs` call: `message` as Node's
    (`ENOENT: no such file or directory, stat '/x'`), `code` (`"ENOENT"`), `syscall`, `path`.
    """
    defexception [:message, :code, :syscall, :path, name: "Error"]
  end

  # libuv's texts where Erlang's (`:file.format_error/1`) differ.
  @descriptions %{
    enoent: "no such file or directory",
    eacces: "permission denied",
    eexist: "file already exists",
    eisdir: "illegal operation on a directory",
    enotdir: "not a directory",
    enotempty: "directory not empty"
  }

  @doc """
  `path.resolve(...paths)`: the absolute, normalized path, relative to the working directory.
  Unlike `Path.expand/1`, a leading `~` is a file name, as in Node.
  """
  def path_resolve(paths) when is_list(paths) do
    paths
    |> Enum.map(&to_string/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(File.cwd!(), fn path, resolved ->
      if Path.type(path) == :absolute, do: path, else: Path.join(resolved, path)
    end)
    |> Path.expand()
  end

  def path_resolve(path), do: path_resolve([path])

  @doc "Node's error of a failed `fs.<syscall>(path)`, from a `File` error reason (`:enoent`)."
  def fs_error(reason, syscall, path) do
    code = reason |> to_string() |> String.upcase()
    description = @descriptions[reason] || to_string(:file.format_error(reason))
    %SystemError{message: "#{code}: #{description}, #{syscall} '#{path}'", code: code, syscall: syscall, path: path}
  end

  @doc """
  The value of a `File` call's `{:ok, value}` (or `:ok`) result, made as `fs.<syscall>(path)`:
  its `{:error, reason}` raises `fs_error/3` (`fs!(File.stat(path), "stat", path)`).
  """
  def fs!({:ok, value}, _syscall, _path), do: value
  def fs!(:ok, _syscall, _path), do: :ok
  def fs!({:error, reason}, syscall, path), do: raise(fs_error(reason, syscall, path))
end
