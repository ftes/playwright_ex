# Outside `Playwright.Client.*`: frames of those modules are the library's, not the caller's.
defmodule Playwright.ClientStackTraceTest do
  # Every API call captures the stack before its message is sent (`_wrapApiCall`). A
  # `File.cwd!/0` per frame (~50 us each, ms under load) delayed messages that JS writes in the
  # same tick: a `page.close()` right after `void route.continue()` hung in the driver, a worker's
  # `evaluate` missed its console. Paths come from the modules' compile info.
  # Not async: it changes the working directory of the VM.
  use ExUnit.Case, async: false
  use Playwright.Test

  import Playwright.Runtime.Heap, only: [get: 2, put: 3]

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.Client.ClientStackTrace
  alias Playwright.Page
  alias Playwright.Route
  alias Playwright.Test.BrowserPool

  @this_file __ENV__.file

  setup_all do
    BrowserPool.browser()
    :ok
  end

  test "the caller's frame is its module's absolute source" do
    %{frames: [frame | _]} = ClientStackTrace.capture_library_stack_trace()
    assert frame.function =~ "Playwright.ClientStackTraceTest."
    assert frame.file == __ENV__.file
  end

  @tag :tmp_dir
  test "frames don't depend on the working directory", %{tmp_dir: tmp_dir} do
    files = fn -> Enum.map(ClientStackTrace.capture_library_stack_trace().frames, & &1.file) end
    [_ | _] = before = files.()
    cwd = File.cwd!()

    try do
      File.cd!(tmp_dir)
      assert files.() == before
    after
      File.cd!(cwd)
    end
  end

  # upstream's `setBoxedStackPrefixes([packageRoot])` and `parseStackFrame`'s Node internals:
  # Playwright Test's frames and Node's never reach the driver, which stats each frame's file
  # (12 ms each for a missing `/home/runner/...` on macOS).
  test "in a test, the runner's frames and OTP's and Elixir's are left out, the test's stay" do
    {:current_stacktrace, raw} = Process.info(self(), :current_stacktrace)
    assert Enum.any?(raw, &(elem(&1, 0) == ExUnit.Runner)) and Enum.any?(raw, &(elem(&1, 0) == :timer))

    [{%{frames: frames}, :ok}] = Enum.map([1], fn _ -> {ClientStackTrace.capture_library_stack_trace(), :ok} end)

    # The function's and the test's.
    assert [_, _] = frames
    assert Enum.all?(frames, &(&1.file == __ENV__.file and &1.function =~ "Playwright.ClientStackTraceTest."))
  end

  # Elixir only: a call without frames of its own in an async function's process
  # (`Promise.async/2`) before its first yield has those of the caller blocked on it, as JS runs
  # that part on the caller's stack. Elsewhere it has none: a fun's tail call drops its frame, and
  # a `Task` or ExUnit's `on_exit` process is no async function (no caller blocked on it is
  # recorded; `$callers` aren't searched). The location is the one sent with the call.
  test "a Task's tail call has no location" do
    page = new_page()
    locations = record_locations(page, ~w(setContent))
    Task.await(Task.async(fn -> Page.set_content!(page, "task") end))

    assert [{"setContent", nil}] = locations.()
  end

  # `fulfill` and `abort` send their channel call from an async function (`Route`).
  test "a route handler's call through an async function has its line, a tail call none" do
    page = new_page()
    locations = record_locations(page, ~w(fulfill abort))

    Page.route!(page, "**/fulfill", fn route ->
      Route.fulfill!(route, body: "fulfilled")
      :ok
    end)

    Page.route!(page, "**/abort", fn route -> Route.abort!(route) end)
    Page.goto!(page, "http://localhost/fulfill")
    {:error, _} = Page.goto(page, "http://localhost/abort")

    assert [{"fulfill", %{file: @this_file, line: line}}, {"abort", nil}] = locations.()
    assert source(line) =~ ~s[Route.fulfill!(route, body: "fulfilled")]
  end

  # `on_exit` callbacks run last registered first: the check runs after the call.
  test "an on_exit callback's tail call has no location" do
    page = new_page()
    locations = record_locations(page, ~w(setContent))
    on_exit(fn -> assert [{"setContent", nil}] = locations.() end)
    on_exit(fn -> Page.set_content!(page, "on_exit") end)
  end

  defp new_page, do: BrowserPool.browser() |> Browser.new_context!() |> BrowserContext.new_page!()

  # Records `{method, location}` of each call of `methods` on the connection of `page` until the
  # test's `on_exit` callbacks ran; returns a fun that reads them. The collector isn't linked, so
  # `on_exit` callbacks read it too.
  defp record_locations(page, methods) do
    {:ok, agent} = Agent.start(fn -> [] end)
    connection = get(page, :_connection)
    onmessage = get(connection, :onmessage)

    put(connection, :onmessage, fn message ->
      method = to_string(message.method)
      if method in methods, do: Agent.update(agent, &[{method, message.metadata.location} | &1])
      onmessage.(message)
    end)

    on_exit(fn ->
      put(connection, :onmessage, onmessage)
      Agent.stop(agent)
    end)

    fn -> agent |> Agent.get(& &1) |> Enum.reverse() end
  end

  # The source line `line` of this file.
  defp source(line), do: @this_file |> File.read!() |> String.split("\n") |> Enum.at(line - 1)
end
