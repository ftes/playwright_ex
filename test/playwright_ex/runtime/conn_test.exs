defmodule PlaywrightEx.RuntimeConnTest do
  # The OTP runtime's semantics (`PlaywrightEx.Runtime.Conn`), driven through the public API: the
  # spike's tests (cases from upstream page-goto, page-wait-for-navigation, page-event-network
  # and page-route specs, plus ordering, re-entrancy, lifetimes and errors). Not named
  # `PlaywrightEx.Runtime.*`: call locations skip library modules.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Promise, as: RuntimePromise
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.TestServer

  @moduletag :page

  describe "page-goto.spec.ts" do
    test "should work @smoke", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      assert Page.url(page) == server.empty_page
    end
  end

  describe "page-wait-for-navigation.spec.ts" do
    test "should work", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)
      # The wait is subscribed when the promise is returned, as the JS call runs until its first await.
      navigation = Page.wait_for_navigation(page)
      Page.evaluate!(page, "url => window.location.href = url", server.prefix <> "/grid.html")
      response = Promise.await!(navigation)
      assert Response.ok(response)
      assert Response.url(response) =~ "grid.html"
    end

    test "should respect timeout", %{page: page, server: server} do
      promise = Page.wait_for_navigation(page, url: "**/frame.html", timeout: 5000)
      Page.goto!(page, server.empty_page)
      error = assert_raise PlaywrightEx.TimeoutError, fn -> Promise.await!(promise) end
      assert error.message =~ "page.waitForNavigation: Timeout 5000ms exceeded."
      assert error.message =~ ~s(waiting for navigation to "**/frame.html" until "load")
      assert error.message =~ ~s(navigated to "#{server.empty_page}")
    end
  end

  describe "page-event-network.spec.ts" do
    test "Page.Events.Request @smoke", %{page: page, server: server} do
      test = self()
      Page.on(page, :request, &send(test, {:request, &1}))
      Page.goto!(page, server.empty_page)
      # Event before reply: the listener ran before goto returned (no wait).
      assert_received {:request, request}
      refute_received {:request, _}
      assert Request.url(request) == server.empty_page
      assert Request.resource_type(request) == "document"
      assert Request.method(request) == "GET"
      assert Request.response!(request)
      assert Request.frame(request) == Page.main_frame(page)
    end
  end

  describe "page-route.spec.ts" do
    test "should intercept @smoke", %{page: page, server: server} do
      test = self()

      Page.route!(page, "**/empty.html", fn route, request ->
        assert Route.request(route) == request
        assert Request.url(request) =~ "empty.html"
        assert Request.headers(request)["user-agent"]
        assert Request.method(request) == "GET"
        assert Request.post_data(request) == nil
        assert Request.is_navigation_request(request)
        assert Request.resource_type(request) == "document"
        assert Request.frame(request) == Page.main_frame(page)
        assert Frame.url(Request.frame(request)) == "about:blank"
        Route.continue!(route)
        send(test, :intercepted)
      end)

      response = Page.goto!(page, server.empty_page)
      assert Response.ok(response)
      assert_received :intercepted
    end

    test "should support async handler w/ times", %{page: page, server: server} do
      Page.route!(
        page,
        "**/empty.html",
        fn route, _ ->
          Process.sleep(100)
          Route.fulfill!(route, body: "<html>intercepted</html>", content_type: "text/html")
        end,
        times: 1
      )

      Page.goto!(page, server.empty_page)
      assert Page.evaluate!(page, "document.body.textContent") == "intercepted"
      Page.goto!(page, server.empty_page)
      refute Page.evaluate!(page, "document.body.textContent") == "intercepted"
    end
  end

  describe "semantics" do
    test "route handler calls back into the API (re-entrancy)", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)

      Page.route!(page, "**/data", fn route, _ ->
        # Calls on the page while the page's own evaluate (below) is awaiting this route.
        assert Page.title!(page) == ""
        assert Page.evaluate!(page, "1 + 2") == 3
        Route.fulfill!(route, body: "from handler", content_type: "text/plain")
      end)

      assert Page.evaluate!(page, "fetch('/data').then(r => r.text())") == "from handler"
    end

    test "console event before evaluate returns, 100 times", %{page: page, server: server} do
      test = self()
      Page.goto!(page, server.empty_page)
      # Some work in the listener, so a gap would show.
      Page.on(page, :console, fn _ -> send(test, {:console, Enum.sum(1..20_000)}) end)

      misses =
        Enum.count(1..100, fn _ ->
          Page.evaluate!(page, "console.log('hello')")

          receive do
            {:console, _} -> false
          after
            0 ->
              assert_receive {:console, _}
              true
          end
        end)

      assert misses == 0
    end

    test "listener awaiting the API does not block dispatch", %{page: page, server: server} do
      test = self()
      Page.on(page, :request, fn request -> send(test, {:response, Request.response!(request)}) end)
      Page.goto!(page, server.empty_page)
      assert_receive {:response, %PlaywrightEx.Response{} = response}
      assert Response.status(response) == 200
    end

    test "listeners run in registration order, once removes itself", %{page: page, server: server} do
      test = self()
      Page.on(page, :request, fn _ -> send(test, :first) end)
      Page.once(page, :request, fn _ -> send(test, :once) end)
      Page.on(page, :request, fn _ -> send(test, :third) end)
      Page.goto!(page, server.empty_page)
      assert {:messages, [:first, :once, :third]} = Process.info(self(), :messages)
      flush()
      Page.goto!(page, server.empty_page)
      assert {:messages, [:first, :third]} = Process.info(self(), :messages)
      flush()
    end

    test "a listener process that dies while dispatch waits for it does not stall dispatch", %{page: page} do
      Page.on(page, :console, fn _ -> Process.exit(self(), :kill) end)
      task = Task.async(fn -> Page.evaluate!(page, "() => { console.log('x'); return 1; }") end)
      assert (Task.yield(task, 10_000) || Task.shutdown(task)) == {:ok, 1}
      wait = Task.async(fn -> Page.remove_all_listeners!(page, :console, behavior: "wait") end)
      assert {:ok, _} = Task.yield(wait, 10_000) || Task.shutdown(wait)
    end

    test "a once listener that fired turns its protocol subscription off", %{page: page} do
      test = self()
      guid = page.guid

      :persistent_term.put({Conn, :on_send}, fn
        %{guid: ^guid, method: "updateSubscription", params: params} -> send(test, {:subscription, params})
        _ -> :ok
      end)

      Page.once(page, :console, fn _ -> :ok end)
      Page.evaluate!(page, "() => console.log('x')")
      Page.evaluate!(page, "() => 1")
      :persistent_term.erase({Conn, :on_send})
      assert_received {:subscription, %{event: "console", enabled: true}}
      assert_received {:subscription, %{event: "console", enabled: false}}
    end

    test "off stops the listener", %{page: page, server: server} do
      test = self()
      listener = fn _ -> send(test, :request) end
      Page.on(page, :request, listener)
      Page.off(page, :request, listener)
      Page.goto!(page, server.empty_page)
      refute_received :request
    end

    test "wait_for_event: promise awaited several times, from several processes", %{page: page, server: server} do
      promise = Page.wait_for_event(page, :request)
      Page.goto!(page, server.empty_page)
      request = Promise.await!(promise)
      assert Request.url(request) == server.empty_page
      assert Promise.await!(promise) == request
      assert Task.await(Task.async(fn -> Promise.await!(promise) end)) == request
    end

    test "wait_for_event with predicate and timeout", %{page: page, server: server} do
      promise = Page.wait_for_event(page, :request, predicate: &(Request.url(&1) =~ "grid"))
      Page.goto!(page, server.empty_page)
      Page.goto!(page, server.prefix <> "/grid.html")
      assert Request.url(Promise.await!(promise)) =~ "grid.html"

      error = assert_raise PlaywrightEx.TimeoutError, fn -> Page.wait_for_event!(page, :popup, timeout: 50) end
      assert error.message =~ ~s(page.waitForEvent: Timeout 50ms exceeded while waiting for event "popup")
      assert error.message =~ ~s(waiting for event "popup")
      # Nothing left behind in the caller's mailbox (subscriptions, timers).
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "a wait's predicate runs outside the wait's API call (savedZone)", %{page: page} do
      test = self()

      predicate = fn _ ->
        send(test, {:zone, PlaywrightEx.Runtime.Zones.current_zone()})
        true
      end

      promise = Page.wait_for_event(page, :console, predicate: predicate)
      Page.evaluate!(page, "() => console.log('x')")
      Promise.await!(promise)
      assert_received {:zone, zone}
      refute Map.has_key?(zone, :apiZone)
      refute Map.has_key?(zone, :apiName)
    end

    test "AbortSignal cancels a wait", %{page: page} do
      controller = AbortController.new()
      signal = AbortController.signal(controller)
      promise = Page.wait_for_event(page, :popup, signal: signal, timeout: 0)
      AbortController.abort(controller, "stop")
      error = assert_raise PlaywrightEx.AbortError, fn -> Promise.await!(promise) end
      assert error.cause == "stop"
      assert error.message =~ "page.waitForEvent: The operation was aborted"
    end

    test "wait_for_event rejects on page close", %{page: page} do
      promise = Page.wait_for_event(page, :popup)
      Page.close!(page)
      error = assert_raise PlaywrightEx.TargetClosedError, fn -> Promise.await!(promise) end
      assert error.message =~ "page.waitForEvent: Target page, context or browser has been closed"
    end
  end

  # JS runs the statements after `await channel.x()` before it dispatches the next message, so an
  # event the call enables sees what they write. The caller is suspended from the moment it sends
  # the call until after the event: the gap between the reply and the caller's next statement, made
  # as long as the test needs (`ChannelOwner.channel_call/5`'s `on_reply` closes it).
  describe "an event right after a reply" do
    test "bindingCall sees Page.expose_function's binding", %{page: page} do
      test = self()

      awaiter =
        suspended_after_reply(page, "exposeBinding", fn ->
          Page.expose_function!(page, "foo", fn a -> send(test, {:called, a}) end)
        end)

      try do
        Page.evaluate!(page, "() => { window.foo(21); }")
        assert_receive {:called, 21}, 2000
      after
        resume(page, awaiter)
      end

      assert_receive {:result, ^awaiter, _disposable}, 5000
    end

    test "bindingCall sees BrowserContext.expose_binding's binding", %{context: context, page: page} do
      test = self()

      awaiter =
        suspended_after_reply(context, "exposeBinding", fn ->
          BrowserContext.expose_binding!(context, "bar", fn _source, a -> send(test, {:called, a}) end)
        end)

      try do
        Page.evaluate!(page, "() => { window.bar(42); }")
        assert_receive {:called, 42}, 2000
      after
        resume(page, awaiter)
      end

      assert_receive {:result, ^awaiter, _disposable}, 5000
    end

    test "locatorHandlerTriggered sees Page.add_locator_handler's handler", %{page: page} do
      test = self()

      Page.set_content!(page, """
      <button onclick="window.clicked = true">Click</button>
      <div id="overlay" style="position: fixed; inset: 0; background: red">Overlay</div>
      """)

      awaiter =
        suspended_after_reply(page, "registerLocatorHandler", fn ->
          Page.add_locator_handler!(page, Page.locator(page, "#overlay"), fn _ ->
            send(test, :handled)
            Page.evaluate!(page, "() => document.querySelector('#overlay').remove()")
          end)
        end)

      click = Task.async(fn -> PlaywrightEx.Locator.click(Page.locator(page, "button"), timeout: 5000) end)

      try do
        assert_receive :handled, 2000
      after
        resume(page, awaiter)
      end

      assert Task.await(click) == :ok
      assert Page.evaluate!(page, "window.clicked") == true
      assert_receive {:result, ^awaiter, :ok}, 5000
    end
  end

  # Runs `call` in a new process, which the connection suspends when it sends `method` to `object`
  # (before the reply can arrive); returns once the reply has been dispatched. The process sends
  # `{:result, pid, result}` when resumed (`resume/2`).
  defp suspended_after_reply(object, method, call) do
    test = self()
    conn = object.conn

    awaiter =
      spawn(fn ->
        receive do: (:go -> :ok)
        send(test, {:result, self(), call.()})
      end)

    guid = object.guid

    :persistent_term.put({Conn, :on_send}, fn
      %{guid: ^guid, method: ^method, id: id} ->
        if self() == conn do
          :erlang.suspend_process(awaiter)
          send(test, {:sent, id})
        end

      _ ->
        :ok
    end)

    send(awaiter, :go)
    assert_receive {:sent, id}, 5000
    :persistent_term.erase({Conn, :on_send})
    connection = Conn.connection(conn)
    wait_until(fn -> id not in PlaywrightEx.Client.Connection.callbacks(connection) end)
    awaiter
  end

  # Only the suspending process (the connection) can resume.
  defp resume(%{conn: conn}, awaiter), do: Conn.run(conn, fn -> :erlang.resume_process(awaiter) end)

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("timed out")

      true ->
        Process.sleep(10)
        wait_until(fun, tries - 1)
    end
  end

  describe "errors and call metadata" do
    test "timeout error: message and call log", %{page: page, server: server} do
      TestServer.set_route(server, "/slow.html", fn conn ->
        Process.sleep(2000)
        Plug.Conn.send_resp(conn, 200, "")
      end)

      {error, stacktrace} =
        try do
          Page.goto!(page, server.prefix <> "/slow.html", timeout: 100)
        rescue
          e -> {e, __STACKTRACE__}
        end

      assert %PlaywrightEx.TimeoutError{name: "TimeoutError"} = error

      assert error.message =~
               ~r/^page\.goto: Timeout 100ms exceeded\.\nCall log:\n  - navigating to "http.*slow\.html", waiting until "load"/

      # A BEAM stacktrace through the client down to this test.
      assert Enum.any?(stacktrace, fn {m, _, _, _} -> m == PlaywrightEx.Client.Frame end)
      assert Enum.any?(stacktrace, fn {m, _, _, _} -> m == __MODULE__ end)
    end

    test "closed target error", %{page: page, server: server} do
      Page.close!(page)
      error = assert_raise PlaywrightEx.TargetClosedError, fn -> Page.goto!(page, server.empty_page) end
      assert error.message == "page.goto: Target page, context or browser has been closed"
    end

    test "metadata the driver receives", %{page: page, server: server} do
      test = self()
      :persistent_term.put({Conn, :on_send}, fn message -> send(test, {:sent, message}) end)
      guid = Page.main_frame(page).guid
      line = __ENV__.line + 1
      Page.goto!(page, server.empty_page)
      :persistent_term.erase({Conn, :on_send})
      assert_received {:sent, %{method: "goto", guid: ^guid, metadata: metadata, params: params}}
      assert metadata.location == %{file: __ENV__.file, line: line, column: 0}
      assert metadata.timeout == 0
      assert metadata.internal == false or metadata.internal == nil
      assert params == %{url: server.empty_page, waitUntil: "load"}
      flush()
    end
  end

  describe "apiZone" do
    # JS: one apiZone object per `_wrapApiCall`; only its first channel call is reported, the
    # others go out internal, whichever async chain makes them.
    test "one API call is reported once across the processes it starts", %{page: page} do
      test = self()
      frame = Page.main_frame(page)
      guid = frame.guid

      :persistent_term.put({Conn, :on_send}, fn
        %{guid: ^guid, method: "title", metadata: metadata} -> send(test, {:internal, metadata.internal})
        _ -> :ok
      end)

      PlaywrightEx.Runtime.Api.call("frame.title", frame, fn ->
        ChannelOwner._wrap_api_call(frame, fn _ ->
          children = for _ <- 1..2, do: RuntimePromise.async(fn -> ChannelOwner.channel_call(frame, :title, %{}) end)
          RuntimePromise.await(RuntimePromise.all(children))
          ChannelOwner.channel_call(frame, :title, %{})
        end)
      end)

      :persistent_term.erase({Conn, :on_send})
      assert_received {:internal, first}
      assert_received {:internal, second}
      assert_received {:internal, third}
      assert Enum.count([first, second, third], &(&1 != true)) == 1
    end
  end

  describe "lifetimes" do
    test "objects are readable as JS after close", %{
      context: context,
      page: page,
      server: server
    } do
      response = Page.goto!(page, server.empty_page)
      request = Response.request(response)
      BrowserContext.close!(context)
      # initializer data: in the handle
      assert Request.url(request) == server.empty_page
      assert Response.status(response) == 200
      # mutable fields: the last value (retained until the browser closes)
      assert Page.url(page) == server.empty_page
    end

    # heap.spec.ts "should collect stale handles" (needs the in-process server's dispatcher limit):
    # the driver's `__dispose__` with reason "gc", simulated.
    test "a call on a collected object raises upstream's error", %{page: page, server: server} do
      response = Page.goto!(page, server.empty_page)
      Conn.run(page.conn, fn -> PlaywrightEx.Client.ChannelOwner._dispose(response, "gc") end)
      {:error, e} = Response.body(response)
      assert e.message =~ "The object has been collected to prevent unbounded heap growth."
    end

    test "a disposed object is readable until its anchor is freed", %{browser: browser, server: server} do
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      BrowserContext.close!(context)
      # Retained under the browser (the context's anchor): last values, as JS.
      assert BrowserContext.browser(context) == browser
      assert BrowserContext.pages(context) == []
      assert Page.is_closed(page)
      assert Page.url(page) == server.empty_page
      # Calls still fail.
      assert {:error, %PlaywrightEx.TargetClosedError{}} = Page.goto(page, server.empty_page)
    end

    test "closed objects keep their fields only: no listeners, callbacks or processes", %{
      browser: browser,
      page: page,
      server: server
    } do
      conn = page.conn
      Page.goto!(page, server.empty_page)
      before = Conn.stats(conn)
      own = PlaywrightEx.BrowserType.launch!(Browser.browser_type(browser))

      for _ <- 1..10 do
        context = Browser.new_context!(own)
        page = BrowserContext.new_page!(context)
        Page.on(page, :request, fn _ -> :ok end)
        Page.route!(page, "**/*", fn route, _ -> Route.continue!(route) end)
        Page.goto!(page, server.empty_page)
        promise = Page.wait_for_event(page, :load, timeout: 0)
        Page.goto!(page, server.empty_page)
        Promise.await!(promise)
        BrowserContext.close!(context)
      end

      Browser.close!(own)
      Process.sleep(50)
      after_ = Conn.stats(conn)
      assert after_.callbacks == 0
      assert after_.subscriptions <= before.subscriptions
      assert after_.frames == 0

      retained = :ets.select(own.table, [{{{:"$1", :__retained__}, :_}, [], [:"$1"]}]) |> MapSet.new()
      assert own.guid in retained

      leftovers =
        for {{guid, local}, value} <- :ets.tab2list(own.table),
            MapSet.member?(retained, guid),
            match?({:map, :_events, _}, sub(local)) or
              (match?({:latch, _}, sub(local)) and match?({:pending, _}, value)),
            do: {guid, local}

      assert leftovers == []
    end

    test "a process's closed contexts are freed when it exits", %{browser: browser, page: page, server: server} do
      conn = page.conn
      Page.goto!(page, server.empty_page)

      cycle = fn ->
        context = Browser.new_context!(browser)
        page = BrowserContext.new_page!(context)
        Page.route!(page, "**/*", fn route, _ -> Route.continue!(route) end)
        Page.goto!(page, server.empty_page)
        BrowserContext.close!(context)
        {context, page}
      end

      # Warm the caches (localUtils' glob cache) in a process that exits.
      Task.await(Task.async(cycle))
      Process.sleep(50)
      before = Conn.stats(conn)

      task = Task.async(fn -> for _ <- 1..10, do: cycle.() end)
      [{context, page} | _] = Task.await(task, 60_000)
      Process.sleep(50)

      assert Conn.stats(conn).rows == before.rows
      # Reads after the creator exited raise (deviation: JS reads the last value).
      assert_raise PlaywrightEx.TargetClosedError, fn -> BrowserContext.browser(context) end
      assert_raise PlaywrightEx.TargetClosedError, fn -> Page.url(page) end
    end

    test "a long-lived process keeps the contexts it closed until it exits (bound: <200 rows each)", %{
      browser: browser,
      page: page
    } do
      conn = page.conn
      Task.await(Task.async(fn -> BrowserContext.close!(Browser.new_context!(browser)) end))
      Process.sleep(50)
      before = Conn.stats(conn)
      test = self()

      holder =
        spawn(fn ->
          # 20 contexts measure the per-context bound as well as 200 (an average), at a tenth of the time.
          for _ <- 1..20 do
            context = Browser.new_context!(browser)
            BrowserContext.new_page!(context)
            BrowserContext.close!(context)
          end

          send(test, :closed)
          receive do: (:exit -> :ok)
        end)

      assert_receive :closed, 20_000
      Process.sleep(50)
      retained = Conn.stats(conn).rows - before.rows
      assert retained > 0
      assert retained / 20 < 200

      send(holder, :exit)
      Process.sleep(100)
      assert Conn.stats(conn).rows == before.rows
    end
  end

  defp sub({ref, sub}) when is_reference(ref), do: sub
  defp sub(sub), do: sub

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
