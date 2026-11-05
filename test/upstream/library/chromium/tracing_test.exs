defmodule PlaywrightEx.Library.Chromium.TracingTest do
  @upstream "tests/library/chromium/tracing.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [rafraf: 1, rafraf: 2]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.Page

  if System.get_env("BROWSER", "chromium") != "chromium", do: @moduletag(skip: "chromium only")

  # testInfo.outputPath(...) is a path in the test's tmp_dir.

  @tag :tmp_dir
  test "should output a trace", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    # process.on('warning', ...): Node process warnings of the client, there are none here.
    page = Browser.new_page!(browser)
    output_trace_file = Path.join(tmp_dir, "trace.json")
    Browser.start_tracing!(browser, page, screenshots: true, path: output_trace_file)
    for _ <- 0..10, do: Page.goto!(page, server.prefix <> "/grid.html")
    Browser.stop_tracing!(browser)
    assert File.exists?(output_trace_file) == true
    Page.close!(page)
  end

  @tag :tmp_dir
  test "should create directories as needed", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    page = Browser.new_page!(browser)
    file_path = Path.join([tmp_dir, "these", "are", "directories", "trace.json"])
    Browser.start_tracing!(browser, page, screenshots: true, path: file_path)
    Page.goto!(page, server.prefix <> "/grid.html")
    Browser.stop_tracing!(browser)
    assert File.exists?(file_path) == true
    Page.close!(page)
  end

  @tag :tmp_dir
  test "should run with custom categories if provided", %{browser: browser, tmp_dir: tmp_dir} do
    page = Browser.new_page!(browser)
    output_trace_file = Path.join(tmp_dir, "trace.json")
    Browser.start_tracing!(browser, page, path: output_trace_file, categories: ["disabled-by-default-cc.debug"])
    rafraf(page)
    Browser.stop_tracing!(browser)

    trace_json = output_trace_file |> File.read!() |> JSON.decode!()

    # NOTE: trace-config is deprecated as per http://crrev.com/c/6628182
    assert ((trace_config = trace_json["metadata"]["trace-config"]) && trace_config =~ "disabled-by-default-cc.debug") ||
             Enum.any?(trace_json["traceEvents"], &(&1["cat"] == "disabled-by-default-cc.debug"))

    Page.close!(page)
  end

  @tag :tmp_dir
  test "should throw if tracing on two pages", %{browser: browser, tmp_dir: tmp_dir} do
    page = Browser.new_page!(browser)
    output_trace_file = Path.join(tmp_dir, "trace.json")
    Browser.start_tracing!(browser, page, path: output_trace_file)
    new_page = Browser.new_page!(browser)
    {:error, error} = Browser.start_tracing(browser, new_page, path: output_trace_file)
    Page.close!(new_page)
    assert error
    Browser.stop_tracing!(browser)
    Page.close!(page)
  end

  @tag :tmp_dir
  test "should return a buffer", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    page = Browser.new_page!(browser)
    output_trace_file = Path.join(tmp_dir, "trace.json")
    Browser.start_tracing!(browser, page, screenshots: true, path: output_trace_file)
    Page.goto!(page, server.prefix <> "/grid.html")
    trace = Browser.stop_tracing!(browser)
    buf = File.read!(output_trace_file)
    assert trace == buf
    Page.close!(page)
  end

  test "should work without options", %{browser: browser, server: server} do
    page = Browser.new_page!(browser)
    Browser.start_tracing!(browser, page)
    Page.goto!(page, server.prefix <> "/grid.html")
    trace = Browser.stop_tracing!(browser)
    assert trace
    Page.close!(page)
  end

  test "should support a buffer without a path", %{browser: browser, server: server} do
    page = Browser.new_page!(browser)
    Browser.start_tracing!(browser, page, screenshots: true)
    Page.goto!(page, server.prefix <> "/grid.html")
    rafraf(page, 100)
    trace = Browser.stop_tracing!(browser)
    assert String.contains?(trace, "screenshot") == true
    Page.close!(page)
  end
end
