defmodule Playwright.Test.CallersTest do
  # User callbacks (route handlers, user listeners) run with the `$callers` of the process that
  # registered them (`Playwright.Runtime.Callers`): `expect`, `step` and an ownership lookup
  # (Ecto's sandbox, Mox) find the test, and an unhandled error fails it and interrupts it (an
  # exit, which a test trapping exits gets as a message).
  use Playwright.Case, async: true

  import ExUnit.CaptureLog

  alias Playwright.BrowserContext
  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Route
  alias Playwright.Screencast
  alias Playwright.Test.Results
  alias Playwright.Test.TestInfo
  alias Playwright.WebSocketRoute

  @url "http://callers.test/"

  # What an ownership lookup sees (DBConnection.Ownership, NimbleOwnership): the first of the
  # process and its `$callers` that owns something.
  defp owner(owners), do: Enum.find([self() | List.wrap(Process.get(:"$callers"))], &(&1 in owners))

  # Waits until the test `pid` has a recorded error (an unhandled one arrives after the action).
  defp await_error(pid, attempts \\ 100, _slept \\ :ok) do
    cond do
      :ets.match_object(Results.table(), {{:test_info, pid, {:error, :_}}, :_}) != [] -> :ok
      attempts == 0 -> flunk("no error recorded")
      true -> await_error(pid, attempts - 1, Process.sleep(50))
    end
  end

  test "a route handler finds the test: ownership, step, soft expect", %{page: page} do
    test_pid = self()

    Page.route!(page, "**/*", fn route ->
      send(test_pid, {:owner, owner([test_pid])})
      send(test_pid, {:step, Test.step("in a route handler", fn -> TestInfo.current().test_pid end)})
      Expect.soft(page) |> Expect.to_have_title!("x", timeout: 1)
      Route.fulfill!(route, body: "<title>ok</title>", content_type: "text/html")
    end)

    Page.goto!(page, @url)
    assert_receive {:owner, ^test_pid}
    assert_receive {:step, ^test_pid}
    assert [{:error, %Playwright.ExpectError{}, _}] = TestInfo.take_errors(self())
  end

  test "a user listener finds the test", %{page: page} do
    test_pid = self()
    Page.on(page, :console, fn _msg -> send(test_pid, {:owner, owner([test_pid]), TestInfo.current().test_pid}) end)
    Page.evaluate!(page, "() => console.log('hi')")
    assert_receive {:owner, ^test_pid, ^test_pid}
  end

  test "an exposed function or binding finds the test", %{context: context, page: page} do
    test_pid = self()

    Page.expose_function!(page, "pageFn", fn ->
      send(test_pid, {:page_fn, owner([test_pid])})
      1
    end)

    BrowserContext.expose_binding!(context, "contextFn", fn _source ->
      send(test_pid, {:context_fn, owner([test_pid])})
      2
    end)

    assert Page.evaluate!(page, "async () => await window.pageFn() + await window.contextFn()") == 3
    assert_receive {:page_fn, ^test_pid}
    assert_receive {:context_fn, ^test_pid}
  end

  test "a wait's predicate (its own process) finds the test", %{page: page} do
    test_pid = self()

    assert {:ok, _} =
             Page.expect_event(page, :console, fn -> Page.evaluate!(page, "() => console.log('hi')") end, fn _ ->
               send(test_pid, {:predicate, owner([test_pid])})
               true
             end)

    assert_receive {:predicate, ^test_pid}
  end

  @overlay """
  <div id="overlay" style="position: fixed; inset: 0; background: red">overlay</div>
  <button onclick="window.clicked = true">go</button>
  """

  test "a locator handler finds the test, and its unhandled error fails the test", %{page: page} do
    Process.flag(:trap_exit, true)
    test_pid = self()
    Page.set_content!(page, @overlay)

    Page.add_locator_handler!(page, Page.locator(page, "#overlay"), fn ->
      send(test_pid, {:handler, owner([test_pid])})
      Page.evaluate!(page, "() => document.querySelector('#overlay').remove()")
      raise "locator handler boom"
    end)

    log =
      capture_log(fn ->
        Locator.click!(Page.locator(page, "button"))
        await_error(self())
      end)

    assert_receive {:handler, ^test_pid}
    assert Page.evaluate!(page, "window.clicked")
    assert [{:error, %RuntimeError{message: "locator handler boom"}, _}] = TestInfo.take_errors(self())
    assert_receive {:EXIT, _, {%RuntimeError{message: "locator handler boom"}, [_ | _]}}, 5000
    refute log =~ "locator handler boom"
  end

  test "a WebSocket route handler and its message and close handlers find the test", %{context: context, page: page} do
    Process.flag(:trap_exit, true)
    test_pid = self()

    # The page's route takes the first socket and falls back to the context's for the second.
    Page.route_web_socket!(page, "**/page", fn ws ->
      send(test_pid, {:page_route, owner([test_pid])})
      WebSocketRoute.on_message(ws, fn _ -> send(test_pid, {:message, owner([test_pid])}) end)
      WebSocketRoute.on_close(ws, fn _code, _reason -> send(test_pid, {:close, owner([test_pid])}) end)
    end)

    BrowserContext.route_web_socket!(context, "**/context", fn ws ->
      send(test_pid, {:context_route, owner([test_pid])})
      WebSocketRoute.on_message(ws, fn _ -> raise "ws message boom" end)
    end)

    Page.evaluate!(page, """
    async () => {
      for (const path of ['page', 'context']) {
        const ws = new WebSocket('ws://callers.test/' + path);
        await new Promise(f => ws.addEventListener('open', f));
        ws.send('hi');
        if (path === 'page') ws.close();
      }
    }
    """)

    assert_receive {:page_route, ^test_pid}
    assert_receive {:message, ^test_pid}
    assert_receive {:close, ^test_pid}
    assert_receive {:context_route, ^test_pid}
    log = capture_log(fn -> await_error(self()) end)
    assert [{:error, %RuntimeError{message: "ws message boom"}, _}] = TestInfo.take_errors(self())
    assert_receive {:EXIT, _, {%RuntimeError{message: "ws message boom"}, _}}, 5000
    refute log =~ "ws message boom"
  end

  test "a route's or WebSocket route's URL predicate finds the test (#239)", %{page: page} do
    test_pid = self()

    url = fn tag ->
      fn _url ->
        send(test_pid, {tag, owner([test_pid])})
        true
      end
    end

    Page.route!(page, url.(:route), &Route.fulfill!(&1, body: "ok"))
    Page.route_web_socket!(page, url.(:ws), fn _ws -> :ok end)
    Page.goto!(page, @url)

    Page.evaluate!(page, """
    async () => {
      const ws = new WebSocket('ws://callers.test/');
      await new Promise(f => ws.addEventListener('open', f));
    }
    """)

    assert_receive {:route, ^test_pid}
    assert_receive {:ws, ^test_pid}
  end

  test "a screencast's onFrame finds the test", %{page: page} do
    test_pid = self()
    Screencast.start!(Page.screencast(page), on_frame: fn _ -> send(test_pid, {:frame, owner([test_pid])}) end)
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
    Page.screenshot!(page)
    assert_receive {:frame, ^test_pid}
    Screencast.stop!(Page.screencast(page))
  end

  test "an unhandled error of a route handler fails the test and interrupts it", %{page: page} do
    Process.flag(:trap_exit, true)

    Page.route!(page, "**/*", fn route ->
      Route.fulfill!(route, body: "ok")
      raise "route boom"
    end)

    log =
      capture_log(fn ->
        Page.goto!(page, @url)
        await_error(self())
      end)

    assert [{:error, %RuntimeError{message: "route boom"}, _}] = TestInfo.take_errors(self())
    assert_receive {:EXIT, _, {%RuntimeError{message: "route boom"}, _}}, 5000
    # Recorded on the test, not logged.
    refute log =~ "route boom"
  end

  # Upstream's `_hasUnhandledError`: the first error fails the test and interrupts it, later ones
  # are not recorded.
  test "a listener's first unhandled error fails the test and interrupts it, later ones are dropped", %{page: page} do
    Process.flag(:trap_exit, true)
    Page.on(page, :console, fn message -> raise "listener boom #{Playwright.ConsoleMessage.text(message)}" end)

    log =
      capture_log(fn ->
        Page.evaluate!(page, "() => { console.log('1'); console.log('2') }")
        await_error(self())
        Process.sleep(200)
      end)

    assert [{:error, %RuntimeError{message: "listener boom 1"}, _}] = TestInfo.take_errors(self())
    # Once (`_isStopped`).
    assert_receive {:EXIT, _, {%RuntimeError{message: "listener boom 1"}, _}}, 5000
    refute_receive {:EXIT, _, _}, 200
    refute log =~ "listener boom"
  end

  test "a listener's exit interrupts the test, also a normal one", %{page: page} do
    Process.flag(:trap_exit, true)
    Page.on(page, :console, fn _ -> exit(:normal) end)
    Page.evaluate!(page, "() => console.log('hi')")
    await_error(self())

    assert [{:exit, :normal, _}] = TestInfo.take_errors(self())
    assert_receive {:EXIT, _, {:exit_in_callback, :normal}}, 5000
  end

  # As a sync listener's error is thrown to `emit`'s caller (`eventEmitter.ts`): the later
  # listeners don't run.
  test "a local emitter's listener run in the test's own process raises there" do
    test_pid = self()
    emitter = Playwright.Client.EventEmitter.new()
    Playwright.Client.EventEmitter.on(emitter, "x", fn _ -> raise "local boom" end)
    Playwright.Client.EventEmitter.on(emitter, "x", fn _ -> send(test_pid, :second) end)
    assert_raise RuntimeError, "local boom", fn -> Playwright.Client.EventEmitter.emit(emitter, "x") end
    refute_received :second
    assert TestInfo.take_errors(self()) == []
  end

  test "registered outside a test: nothing found, the error is logged", %{page: page} do
    test_pid = self()

    # A process that is not the test's (no `$callers`) registers the callbacks.
    pid =
      spawn(fn ->
        Page.route!(page, "**/*", fn route ->
          send(test_pid, {:owner, owner([test_pid]), TestInfo.current()})
          Route.fulfill!(route, body: "ok")
          raise "outside boom"
        end)

        send(test_pid, :routed)
        Process.sleep(:infinity)
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    assert_receive :routed

    log =
      capture_log(fn ->
        Page.goto!(page, @url)
        assert_receive {:owner, nil, nil}
        Process.sleep(300)
      end)

    assert log =~ "Uncaught in event listener" and log =~ "outside boom"
    assert TestInfo.take_errors(self()) == []
  end
end
