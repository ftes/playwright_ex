defmodule PlaywrightEx.FailuresFormatter do
  @moduledoc """
  An ExUnit formatter that appends each failed test to the file named by `PW_FAILURES_FILE` (if set), one
  `file:line<TAB>module: test name` line per failure (a failed `setup_all` reports its module at
  line 1), as soon as it fails. CI reads it after the first run, which the `--failed` rerun hides.
  """
  use GenServer

  @impl true
  def init(_opts), do: {:ok, System.get_env("PW_FAILURES_FILE", "")}

  @impl true
  def handle_cast({:test_finished, %ExUnit.Test{state: {:failed, _}} = test}, path) do
    write(path, "#{Path.relative_to_cwd(test.tags.file)}:#{test.tags.line}", "#{inspect(test.module)}: #{test.name}")
    {:noreply, path}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{state: {:failed, _}} = module}, path) do
    write(path, "#{Path.relative_to_cwd(module.file)}:1", "#{inspect(module.name)}: setup_all failed")
    {:noreply, path}
  end

  def handle_cast(_event, path), do: {:noreply, path}

  defp write("", _location, _name), do: :ok
  defp write(path, location, name), do: File.write!(path, "#{location}\t#{name}\n", [:append])
end
