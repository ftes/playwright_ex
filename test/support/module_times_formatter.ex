defmodule PlaywrightEx.ModuleTimesFormatter do
  @moduledoc """
  An ExUnit formatter that appends each test module's wall time (`setup_all` included) to the
  file named by `PW_MODULE_TIMES_FILE` (if set), one `milliseconds<TAB>file<TAB>module` line per
  module (per instance of a parameterized module, its parameters after the name). CI prints the
  slowest: `mix test --slowest-modules` would force `--trace`, which runs one module at a time
  without timeouts.
  """
  use GenServer

  @impl true
  def init(_opts), do: {:ok, {System.get_env("PW_MODULE_TIMES_FILE", ""), %{}}}

  @impl true
  def handle_cast(_event, {"", _started} = state), do: {:noreply, state}

  def handle_cast({:module_started, %ExUnit.TestModule{} = module}, {path, started}) do
    {:noreply, {path, Map.put(started, {module.name, module.parameters}, System.monotonic_time(:millisecond))}}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{} = module}, {path, started}) do
    case Map.pop(started, {module.name, module.parameters}) do
      {nil, started} ->
        {:noreply, {path, started}}

      {start, started} ->
        ms = System.monotonic_time(:millisecond) - start

        name =
          if module.parameters == %{},
            do: inspect(module.name),
            else: "#{inspect(module.name)} #{inspect(module.parameters)}"

        File.write!(path, "#{ms}\t#{Path.relative_to_cwd(module.file)}\t#{name}\n", [:append])
        {:noreply, {path, started}}
    end
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
