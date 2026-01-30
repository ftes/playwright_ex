defmodule PlaywrightExTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Selector
  alias PlaywrightEx.Tracing

  doctest PlaywrightEx

  @open_trace_viewer_for_manual_inspection false
  @moduletag tmp_dir: @open_trace_viewer_for_manual_inspection

  setup context do
    if @open_trace_viewer_for_manual_inspection do
      on_exit_open_trace(context.browser_context.tracing.guid, context.tmp_dir, @timeout)
    end

    :ok
  end

  test "visit elixir-lang.org, then assert and navigate", %{frame: frame} do
    {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)

    assert_has(frame.guid, Selector.role("heading", "Elixir is a dynamic, functional language"))
    refute_has(frame.guid, Selector.role("heading", "I made this up"))

    {:ok, _} = Frame.click(frame.guid, selector: Selector.link("Install"), timeout: @timeout)
    assert_has(frame.guid, Selector.link("macOS"))
  end

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
