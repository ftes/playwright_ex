defmodule PlaywrightEx.Page.PageWaitForFunctionTest do
  @upstream "tests/page/page-wait-for-function.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.Errors.TimeoutError
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  test "should timeout", %{page: page} do
    start_time = System.monotonic_time(:millisecond)
    timeout = 42
    Page.wait_for_timeout!(page, timeout)
    refute System.monotonic_time(:millisecond) - start_time < timeout / 2
  end

  test "should accept a string", %{page: page} do
    watchdog = Task.async(fn -> Page.wait_for_function!(page, "window.__FOO === 1") end)
    Page.evaluate!(page, "() => window['__FOO'] = 1")
    Task.await(watchdog)
  end

  @tag skip: "not ported: addInitScript"
  test "should work when resolved right before execution context disposal"

  test "should poll on interval", %{page: page} do
    polling = 100

    time_delta =
      Page.wait_for_function!(
        page,
        """
        () => {
          if (!window['__startTime']) {
            window['__startTime'] = window.builtins.Date.now();
            return false;
          }
          return window.builtins.Date.now() - window['__startTime'];
        }
        """,
        %{},
        polling: polling
      )

    refute JSHandle.json_value!(time_delta) < polling
  end

  @tag skip: "not ported: ConsoleMessage"
  test "should avoid side effects after timeout"

  test "should throw on polling:mutation", %{page: page} do
    {:error, error} = Page.wait_for_function(page, "() => true", %{}, polling: "mutation")
    assert Exception.message(error) =~ "Unknown polling option: mutation"
  end

  test "should poll on raf", %{page: page} do
    watchdog =
      Task.async(fn -> Page.wait_for_function!(page, "() => window['__FOO'] === 'hit'", %{}, polling: :raf) end)

    Page.evaluate!(page, "() => window['__FOO'] = 'hit'")
    Task.await(watchdog)
  end

  test "should fail with predicate throwing on first call", %{page: page} do
    {:error, error} = Page.wait_for_function(page, "() => { throw new Error('oh my'); }")
    assert Exception.message(error) =~ "oh my"
  end

  test "should fail with predicate throwing sometimes", %{page: page} do
    {:error, error} =
      Page.wait_for_function(page, """
      () => {
        window['counter'] = (window['counter'] || 0) + 1;
        if (window['counter'] === 3)
          throw new Error('Bad counter!');
        return window['counter'] === 5 ? 'result' : false;
      }
      """)

    assert Exception.message(error) =~ "Bad counter!"
  end

  test "should fail with ReferenceError on wrong page", %{page: page} do
    {:error, error} = Page.wait_for_function(page, "() => globalVar === 123")
    assert Exception.message(error) =~ "globalVar"
  end

  test "should work with strict CSP policy", %{page: page, server: server} do
    PlaywrightEx.TestServer.set_csp(server, "/empty.html", "script-src " <> server.prefix)
    Page.goto!(page, server.empty_page)

    p =
      Task.async(fn -> Page.wait_for_function(page, "() => window['__FOO'] === 'hit'", %{}, polling: :raf) end)

    Page.wait_for_timeout!(page, 1000)
    Page.evaluate!(page, "() => window['__FOO'] = 'hit'")
    assert {:ok, _} = Task.await(p)
  end

  test "should throw on bad polling value", %{page: page} do
    {:error, error} = Page.wait_for_function(page, "() => !!document.body", %{}, polling: "unknown")
    assert error
    assert Exception.message(error) =~ "polling"
  end

  test "should throw negative polling interval", %{page: page} do
    {:error, error} = Page.wait_for_function(page, "() => !!document.body", %{}, polling: -10)
    assert error
    assert Exception.message(error) =~ "Cannot poll with non-positive interval"
  end

  test "should return the success value as a JSHandle", %{page: page} do
    assert JSHandle.json_value!(Page.wait_for_function!(page, "() => 5")) == 5
  end

  test "should return the window as a success value", %{page: page} do
    assert Page.wait_for_function!(page, "() => window")
  end

  test "should accept ElementHandle arguments", %{page: page} do
    Page.set_content!(page, "<div></div>")
    div = Page.query_selector!(page, "div")
    wait_for_function = Task.async(fn -> Page.wait_for_function!(page, "element => !element.parentElement", div) end)
    assert Task.yield(wait_for_function, 0) == nil
    Page.evaluate!(page, "element => element.remove()", div)
    Task.await(wait_for_function)
  end

  test "should respect timeout", %{page: page} do
    {:error, error} = Page.wait_for_function(page, "false", %{}, timeout: 10)
    assert error
    assert Exception.message(error) =~ "page.waitForFunction: Timeout 10ms exceeded"
    assert %TimeoutError{} = error
  end

  test "should respect default timeout", %{page: page} do
    Page.set_default_timeout(page, 1)
    {:error, error} = Page.wait_for_function(page, "false")
    assert %TimeoutError{} = error
    assert Exception.message(error) =~ "page.waitForFunction: Timeout 1ms exceeded"
  end

  test "should disable timeout when its set to 0", %{page: page} do
    watchdog =
      Task.async(fn ->
        Page.wait_for_function!(
          page,
          """
          () => {
            window['__counter'] = (window['__counter'] || 0) + 1;
            return window['__injected'];
          }
          """,
          %{},
          timeout: 0,
          polling: 10
        )
      end)

    Page.wait_for_function!(page, "() => window['__counter'] > 10")
    Page.evaluate!(page, "() => window['__injected'] = true")
    Task.await(watchdog)
  end

  test "should survive cross-process navigation", %{page: page, server: server} do
    wait_for_function = Task.async(fn -> Page.wait_for_function!(page, "window.__FOO === 1") end)
    Page.goto!(page, server.empty_page)
    assert Task.yield(wait_for_function, 0) == nil
    Page.reload!(page)
    assert Task.yield(wait_for_function, 0) == nil
    Page.goto!(page, server.cross_process_prefix <> "/grid.html")
    assert Task.yield(wait_for_function, 0) == nil
    Page.evaluate!(page, "() => window['__FOO'] = 1")
    assert Task.await(wait_for_function)
  end

  test "should survive navigations", %{page: page, server: server} do
    watchdog = Task.async(fn -> Page.wait_for_function!(page, "() => window['__done']") end)
    Page.goto!(page, server.empty_page)
    Page.goto!(page, server.prefix <> "/consolelog.html")
    Page.evaluate!(page, "() => window['__done'] = true")
    Task.await(watchdog)
  end

  test "should work with multiline body", %{page: page} do
    result =
      Page.wait_for_function!(page, """

        (() => true)()
      """)

    assert JSHandle.json_value!(result) == true
  end

  test "should wait for predicate with arguments", %{page: page} do
    Page.wait_for_function!(page, "({ arg1, arg2 }) => arg1 + arg2 === 3", %{arg1: 1, arg2: 2})
  end

  @tag skip: "not ported: ConsoleMessage"
  test "should not be called after finishing successfully"

  @tag skip: "not ported: ConsoleMessage"
  test "should not be called after finishing unsuccessfully"

  test "should throw when frame is detached", %{page: page, server: server} do
    Utils.attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    promise = Task.async(fn -> Frame.wait_for_function(frame, "() => false") end)
    Utils.detach_frame(page, "frame1")
    {:error, error} = Task.await(promise)
    assert error
    assert Exception.message(error) =~ ~r/frame.waitForFunction: (Frame was detached|Execution context was destroyed)/
  end
end
