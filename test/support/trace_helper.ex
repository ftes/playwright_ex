defmodule PlaywrightEx.TraceHelper do
  @moduledoc false

  alias PlaywrightEx.Tracing

  def on_exit_open_trace(tracing_id, tmp_dir, timeout) do
    {:ok, _} = Tracing.tracing_start(tracing_id, screenshots: true, snapshots: true, sources: true, timeout: timeout)
    {:ok, _} = Tracing.tracing_start_chunk(tracing_id, timeout: timeout)

    ExUnit.Callbacks.on_exit(fn ->
      {:ok, zip_file} = Tracing.tracing_stop_chunk(tracing_id, timeout: timeout)
      {:ok, _} = Tracing.tracing_stop(tracing_id, timeout: timeout)

      trace_file = Path.join(tmp_dir, "trace.zip")
      File.cp!(zip_file.absolute_path, trace_file)

      spawn(fn ->
        executable = :playwright_ex |> Application.fetch_env!(:executable) |> Path.expand()
        System.cmd(executable, ["show-trace", trace_file])
      end)
    end)
  end
end
