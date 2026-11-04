# Spike 6: BrowserType.connect to `run-server` through the local driver's LocalUtils/JsonPipe
# (nested Connection on the same baton); download saveAs and setInputFiles over the remote streams.
defmodule PlaywrightJS.RemoteTest do
  use ExUnit.Case, async: false
  import PlaywrightJS.Matchers.Expect
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Runtime.{Heap, Promise}
  alias PlaywrightJS.Client.{Browser, BrowserContext, BrowserType, Connection, Download, Locator, Page, Playwright}

  @cli Path.expand("../../node_modules/playwright/cli.js", __DIR__)

  defp start_server do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    node = System.find_executable("node")
    server = Port.open({:spawn_executable, node}, [:binary, :exit_status, :stderr_to_stdout, args: [@cli, "run-server", "--port", "#{port}"]])
    wait_listening(server, "")
    {server, "ws://localhost:#{port}/"}
  end

  defp wait_listening(server, acc) do
    receive do
      {^server, {:data, data}} -> if (acc <> data) =~ "Listening on", do: :ok, else: wait_listening(server, acc <> data)
      {^server, {:exit_status, status}} -> raise "run-server exited: #{status} #{acc}"
    after
      15_000 -> raise "run-server did not start: #{acc}"
    end
  end

  defp stop_server(server) do
    {:os_pid, os_pid} = Port.info(server, :os_pid)
    Port.close(server)
    System.cmd("kill", ["-9", "#{os_pid}"])
  end

  @tag timeout: 120_000
  test "connect, download save_as, set_input_files (buffer and path) over the remote streams" do
    {server, endpoint} = start_server()
    %{playwright: playwright, stop: stop} = PlaywrightJS.OutOfProcess.start()
    chromium = Playwright.chromium(playwright)

    browser = BrowserType.connect(chromium, endpoint)
    assert Browser.is_connected(browser)
    remote = Heap.get(browser, :_connection)
    assert Connection.is_remote(remote)
    # Nested connection: own heap, same baton.
    assert remote.conn.pid == Heap.get(Playwright.chromium(playwright), :_connection).conn.pid
    refute remote.conn.table == Heap.get(Playwright.chromium(playwright), :_connection).conn.table

    context = Browser.new_context(browser)
    page = BrowserContext.new_page(context)
    Page.goto(page, TestHelper.fixture_url("form.html"))
    expect(page) |> to_have_title("Sign up")

    # set_input_files with a >1.2 MB buffer (payload inlined in the JsonPipe message)
    big = :crypto.strong_rand_bytes(1_300_000)
    page |> Page.get_by_label("Attachment") |> Locator.set_input_files(%{name: "big.bin", mimeType: "application/octet-stream", buffer: big})
    expect(Page.locator(page, "#file-info")) |> to_have_text("big.bin (1300000 bytes)")

    # set_input_files with a local path (createTempFiles + WritableStream)
    tmp = Path.join(System.tmp_dir!(), "pw-remote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "upload.bin")
    File.write!(path, :crypto.strong_rand_bytes(3_000_000))
    page |> Page.get_by_label("Attachment") |> Locator.set_input_files(path)
    expect(Page.locator(page, "#file-info")) |> to_have_text("upload.bin (3000000 bytes)")

    # download.saveAs (saveAsStream + Stream.read)
    Page.goto(page, TestHelper.fixture_url("result.html"))
    download_promise = Promise.async(fn -> Page.wait_for_event(page, "download") end)
    page |> Page.get_by_role("link", %{name: "Download report"}) |> Locator.click()
    download = Promise.await(download_promise)
    saved = Path.join([tmp, "out", "report.csv"])
    Download.save_as(download, saved)
    assert File.read!(saved) == "a,b\n1,2"

    # A local browser on the same baton keeps working alongside the remote one.
    local = BrowserType.launch(chromium)
    local_page = local |> Browser.new_context() |> BrowserContext.new_page()
    assert Page.evaluate(local_page, "1 + 1") == 2
    assert Page.evaluate(page, "2 + 2") == 4
    Browser.close(local)

    Browser.close(browser)
    refute Browser.is_connected(browser)
    # The JsonPipe close is fire-and-forget (connection 'close' listener); let it land before
    # closing the driver's stdio, or node reports EPIPE on its pending writes.
    Process.sleep(200)
    stop.()
    stop_server(server)
  end
end
