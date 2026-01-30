defmodule PlaywrightEx.TracingTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Tracing

  @timeout Application.compile_env(:playwright_ex, :timeout)

  setup do
    {:ok, browser} = PlaywrightEx.launch_browser(:chromium, timeout: @timeout)
    {:ok, browser_context} = Browser.new_context(browser.guid, timeout: @timeout)
    {:ok, page} = BrowserContext.new_page(browser_context.guid, timeout: @timeout)
    on_exit(fn -> Browser.close(browser.guid, timeout: @timeout) end)
    [tracing_id: browser_context.tracing.guid, frame: page.main_frame]
  end

  describe "group/3" do
    test "writes name and location with nesting", %{tracing_id: tracing_id, frame: frame} do
      start_tracing(tracing_id)

      Tracing.group(tracing_id, [name: "Outer Group", timeout: @timeout], fn ->
        {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)

        Tracing.group(
          tracing_id,
          [name: "Inner Group with location", location: [file: __ENV__.file, line: 30], timeout: @timeout],
          fn ->
            {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/blog/", timeout: @timeout)
          end
        )
      end)

      trace = stop_tracing(tracing_id)
      assert trace =~ "Outer Group"
      assert trace =~ "Inner Group with location"
      assert trace =~ "tracing_test.exs"
    end

    test "returns function result", %{tracing_id: tracing_id, frame: frame} do
      start_tracing(tracing_id)

      result =
        Tracing.group(tracing_id, [name: "Wrapped Navigation", timeout: @timeout], fn ->
          {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)
          :success
        end)

      assert result == :success

      stop_tracing(tracing_id)
    end

    test "cleans up even when function raises", %{tracing_id: tracing_id, frame: frame} do
      start_tracing(tracing_id)

      assert_raise RuntimeError, "intentional error", fn ->
        Tracing.group(tracing_id, [name: "Error Group", timeout: @timeout], fn ->
          {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)
          raise "intentional error"
        end)
      end

      stop_tracing(tracing_id)
    end
  end

  defp start_tracing(tracing_id) do
    {:ok, _} = Tracing.tracing_start(tracing_id, timeout: @timeout)
    {:ok, _} = Tracing.tracing_start_chunk(tracing_id, timeout: @timeout)
  end

  defp stop_tracing(tracing_id) do
    {:ok, zip_file} = Tracing.tracing_stop_chunk(tracing_id, timeout: @timeout)
    {:ok, _} = Tracing.tracing_stop(tracing_id, timeout: @timeout)
    {:ok, handle} = :zip.zip_open(String.to_charlist(zip_file.absolute_path), [:memory])
    {:ok, {_, trace_contents}} = :zip.zip_get(~c"trace.trace", handle)
    :ok = :zip.zip_close(handle)

    trace_contents
  end
end
