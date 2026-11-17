defmodule Playwright.Test.CallersTest do
  # User callbacks (route handlers, user listeners) run with the `$callers` of the process that
  # registered them (`Playwright.Runtime.Callers`): `expect`, `step` and an ownership lookup
  # (Ecto's sandbox, Mox) find the test, and an unhandled error fails it and stops it (an exit,
  # which these tests trap to see it: a test that traps exits isn't stopped).
  use Playwright.Case, async: true

  import ExUnit.CaptureLog

  alias Playwright.BrowserContext
  alias Playwright.Expect
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Route
  alias Playwright.Screencast
  alias Playwright.Test.TestInfo
  alias Playwright.WebSocketRoute

  @url "http://callers.test/"

  # What an ownership lookup sees (DBConnection.Ownership, NimbleOwnership): the first of the
  # process and its `$callers` that owns something.
  defp owner(owners), do: Enum.find([self() | List.wrap(Process.get(:"$callers"))], &(&1 in owners))

  # The interrupt of this test (`TestInfo._unhandled_error/2`), whose exit it trapped: the error.
  # Taken back, so that the pool does not count the test as failed.
  defp take_interrupt do
    assert_receive {:EXIT, _pid, exit_reason}, 5000
    assert {^exit_reason, error} = TestInfo.take_interrupt(self())
    # Not among the errors the end of the body raises.
    assert TestInfo.take_errors(self()) == []
    error
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
        assert {:error, %RuntimeError{message: "locator handler boom"}, [_ | _]} = take_interrupt()
      end)

    assert_receive {:handler, ^test_pid}
    assert Page.evaluate!(page, "window.clicked")
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
    log = capture_log(fn -> assert {:error, %RuntimeError{message: "ws message boom"}, _} = take_interrupt() end)
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

  test "a route handler that raises fails the test and stops it at once", %{page: page} do
    Process.flag(:trap_exit, true)

    Page.route!(page, "**/*", fn route ->
      Route.fulfill!(route, body: "ok")
      raise "route boom"
    end)

    log =
      capture_log(fn ->
        Page.goto!(page, @url)
        assert {:error, %RuntimeError{message: "route boom"}, _} = take_interrupt()
      end)

    # The test's failure, not logged.
    refute log =~ "route boom"
  end

  test "an assertion in a :dialog listener stops the test at once, with its message", %{page: page} do
    Process.flag(:trap_exit, true)
    test_pid = self()

    Page.on(page, :dialog, fn dialog ->
      send(test_pid, {:dialog, dialog})
      assert Playwright.Dialog.message(dialog) == "expected"
      Playwright.Dialog.accept!(dialog)
    end)

    # The dialog stays open, so the call hangs.
    Task.start(fn -> Page.evaluate(page, "() => alert('actual')") end)
    assert_receive {:dialog, dialog}, 5000

    # As ExUnit reports the exit of a test that does not trap it.
    assert_receive {:EXIT, _pid, {%ExUnit.AssertionError{} = error, [_ | _]} = exit_reason}, 1000
    assert Exception.message(error) =~ "Assertion with == failed"
    assert Exception.format_exit(exit_reason) =~ ~S|code:  assert Playwright.Dialog.message(dialog) == "expected"|

    assert {^exit_reason, {:error, ^error, _}} = TestInfo.take_interrupt(self())

    Playwright.Dialog.dismiss!(dialog)
  end

  # Upstream's `_hasUnhandledError`: only the first error fails the test and stops it.
  test "a second unhandled error is dropped", %{page: page} do
    Process.flag(:trap_exit, true)
    Page.on(page, :console, fn message -> raise "listener boom #{Playwright.ConsoleMessage.text(message)}" end)

    log =
      capture_log(fn ->
        Page.evaluate!(page, "() => { console.log('1'); console.log('2') }")
        Page.evaluate!(page, "() => console.log('3')")
      end)

    assert {:error, %RuntimeError{message: "listener boom 1"}, _} = take_interrupt()
    refute_receive {:EXIT, _, _}, 200
    refute log =~ "listener boom"
  end

  test "a listener's exit stops the test, also a normal one", %{page: page} do
    Process.flag(:trap_exit, true)
    Page.on(page, :console, fn _ -> exit(:normal) end)
    Page.evaluate!(page, "() => console.log('hi')")
    assert_receive {:EXIT, _, {:exit_in_callback, :normal}}, 5000
    assert {_exit_reason, {:exit, :normal, _}} = TestInfo.take_interrupt(self())
  end

  test "once the body ended, an unhandled error is logged and stops nothing", %{page: page} do
    Process.flag(:trap_exit, true)
    Page.on(page, :console, fn _ -> raise "late boom" end)
    # The end of the body, as the `test` macro's.
    assert TestInfo.finish(self()) == []

    log = capture_log(fn -> Page.evaluate!(page, "() => console.log('hi')") end)
    assert log =~ "Uncaught in event listener" and log =~ "late boom"
    refute_receive {:EXIT, _, _}, 200
    assert TestInfo.take_interrupt(self()) == nil
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
