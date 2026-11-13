defmodule PlaywrightEx.Test.RequestContextTest do
  # A registered test's request contexts (Playwright Test's `didCreateRequestContext` and
  # `willCloseRequestContext`), on fake tests as `PlaywrightEx.Test.ArtifactsTest`'s.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Results
  alias PlaywrightEx.TestServer

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  setup do
    server = TestServer.server(start_supervised!({TestServer, dir_path: System.tmp_dir!()}))
    TestServer.set_content(server, "/api", ~s({"ok": true}), "application/json")
    %{server: server}
  end

  defp fake_test(tags) do
    parent = self()
    name = "t#{System.unique_integer([:positive])}"

    pid =
      spawn(fn ->
        context =
          Map.merge(tags, %{
            test_pid: self(),
            module: __MODULE__,
            test: :"test #{name}",
            file: __ENV__.file,
            line: 1,
            playwright_ex: :marked
          })

        send(parent, {:registered, PlaywrightEx.Test.__register__(context)})

        receive do
          {:end, reason} ->
            Results.notify({:passed, self()})
            exit(reason)
        end
      end)

    assert_receive {:registered, test}
    on_exit(fn -> File.rm_rf!(test.output_dir) end)

    # Its leases released, also when the test fails before the fake test's end.
    on_exit(fn ->
      Process.exit(pid, :kill)
      Pool.release(pid)
    end)

    run = fn fun ->
      Task.await(
        Task.async(fn ->
          Process.put(:"$callers", [pid])
          fun.()
        end),
        30_000
      )
    end

    %{pid: pid, dir: test.output_dir, run: run}
  end

  defp finish(test) do
    ref = Process.monitor(test.pid)
    send(test.pid, {:end, :shutdown})
    assert_receive {:DOWN, ^ref, :process, _, _}
    capture_io(fn -> PlaywrightEx.Test.__finish__(test.pid, 10_000) end)
  end

  defp trace_text(dir) do
    {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "trace.zip")), [:memory])
    Enum.map_join(files, "\n", fn {_name, data} -> data end)
  end

  test "a context's request and the test's own request contexts are traced", %{browser: browser, server: server} do
    test = fake_test(%{trace: :on})

    test.run.(fn ->
      context = Browser.new_context!(browser)
      APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/api?from=context")
      closed = Browser.new_context!(browser)
      APIRequestContext.get!(BrowserContext.request(closed), server.prefix <> "/api?from=closed")
      BrowserContext.close!(closed)

      request = new_request(browser)
      APIRequestContext.get!(request, server.prefix <> "/api?from=standalone")
      disposed = new_request(browser)
      APIRequestContext.get!(disposed, server.prefix <> "/api?from=disposed")
      APIRequestContext.dispose!(disposed)
    end)

    finish(test)
    text = trace_text(test.dir)
    for from <- ~w(context closed standalone disposed), do: assert(text =~ "from=#{from}", "from=#{from} not traced")
  end

  test "the test's request contexts left are disposed at its end", %{browser: browser, server: server} do
    test = fake_test(%{})
    other = new_request(browser)

    request =
      test.run.(fn ->
        request = new_request(browser)
        assert APIResponse.status(APIRequestContext.get!(request, server.prefix <> "/api")) == 200
        request
      end)

    finish(test)
    assert {:error, %PlaywrightEx.TargetClosedError{}} = APIRequestContext.get(request, server.prefix <> "/api")
    assert APIResponse.status(APIRequestContext.get!(other, server.prefix <> "/api")) == 200
    APIRequestContext.dispose!(other)
  end

  defp new_request(browser), do: APIRequest.new_context!(Playwright.request(BrowserPool.playwright(browser)))
end
