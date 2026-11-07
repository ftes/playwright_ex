defmodule PlaywrightEx.Library.UnrouteBehaviorTest do
  @upstream "tests/library/unroute-behavior.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime

  @moduletag :page

  # `const routeBarrier = new Promise(f => continueRouteCallback = f)`: a handler sends
  # `{:route_callback, self()}` (`routeCallback()`), then awaits the barrier, which the test
  # opens with `send(pid, :continue)` (`continueRouteCallback()`). The handler polls its mailbox
  # with `waitForTimeout`, so the driver keeps running meanwhile (as JS awaits).
  defp await_barrier(page) do
    receive do
      :continue -> :ok
    after
      0 ->
        Page.wait_for_timeout!(page, 10)
        await_barrier(page)
    end
  end

  # `await new Promise(() => {})`: never settles (a wait that never fires, ended by the close).
  defp await_forever(page) do
    PlaywrightEx.Promise.await(Page.wait_for_event(page, :console, predicate: fn _ -> false end, timeout: 0))
  end

  test "RO-186 context.unroute should not wait for pending handlers to complete",
       %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()

    BrowserContext.route!(context, ~r/.*/, fn route ->
      send(me, :second_handler_called)
      Route.continue!(route)
    end)

    handler = fn route ->
      send(me, {:route_callback, self()})
      await_barrier(page)
      Route.fallback!(route)
    end

    BrowserContext.route!(context, ~r/.*/, handler)
    navigation_promise = Runtime.Promise.async(fn -> Page.goto!(page, server.empty_page) end)
    assert_receive {:route_callback, handler_pid}, 5000
    BrowserContext.unroute!(context, ~r/.*/, handler)
    send(handler_pid, :continue)
    Runtime.Promise.await(navigation_promise)
    assert_received :second_handler_called
  end

  test "RO-187 context.unrouteAll removes all handlers", %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    BrowserContext.route!(context, "**/*", &Route.abort/1)
    BrowserContext.route!(context, "**/empty.html", &Route.abort/1)
    BrowserContext.unroute_all!(context)
    Page.goto!(page, server.empty_page)
  end

  test "RO-188 context.unrouteAll should wait for pending handlers to complete",
       %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()

    BrowserContext.route!(context, ~r/.*/, fn route ->
      send(me, :second_handler_called)
      Route.abort!(route)
    end)

    handler = fn route ->
      send(me, {:route_callback, self()})
      await_barrier(page)
      Route.fallback!(route)
    end

    BrowserContext.route!(context, ~r/.*/, handler)
    navigation_promise = Runtime.Promise.async(fn -> Page.goto!(page, server.empty_page) end)
    assert_receive {:route_callback, handler_pid}, 5000

    unroute_promise =
      Runtime.Promise.async(fn -> BrowserContext.unroute_all!(context, behavior: :wait) end, shared: true)

    Process.sleep(500)
    refute Runtime.Promise.settled?(unroute_promise)
    send(handler_pid, :continue)
    Runtime.Promise.await(unroute_promise)
    Runtime.Promise.await(navigation_promise)
    refute_received :second_handler_called
  end

  test "RO-189 context.unrouteAll should not wait for pending handlers to complete if behavior is ignoreErrors",
       %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()

    BrowserContext.route!(context, ~r/.*/, fn route ->
      send(me, :second_handler_called)
      Route.abort!(route)
    end)

    handler = fn _route ->
      send(me, {:route_callback, self()})
      await_barrier(page)
      raise "Handler error"
    end

    BrowserContext.route!(context, ~r/.*/, handler)
    navigation_promise = Runtime.Promise.async(fn -> Page.goto(page, server.empty_page) end)
    assert_receive {:route_callback, handler_pid}, 5000

    unroute_promise =
      Runtime.Promise.async(fn -> BrowserContext.unroute_all!(context, behavior: :ignore_errors) end, shared: true)

    Process.sleep(500)
    Runtime.Promise.await(unroute_promise)
    send(handler_pid, :continue)
    Runtime.Promise.await(navigation_promise)
    # The error in the unrouted handler should be silently caught and remaining handler called.
    refute_received :second_handler_called
  end

  test "RO-190 page.close should not wait for active route handlers on the owning context",
       %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()
    BrowserContext.route!(context, ~r/.*/, fn _route -> send(me, :route_callback) end)
    Page.route!(page, ~r/.*/, &Route.fallback!/1)
    Runtime.Promise.void(fn -> Page.goto(page, server.empty_page) end)
    assert_receive :route_callback, 5000
    Page.close!(page)
  end

  test "RO-191 context.close should not wait for active route handlers on the owned pages",
       %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()
    Page.route!(page, ~r/.*/, fn _route -> send(me, :route_callback) end)
    Page.route!(page, ~r/.*/, &Route.fallback!/1)
    Runtime.Promise.void(fn -> Page.goto(page, server.empty_page) end)
    assert_receive :route_callback, 5000
    BrowserContext.close!(context)
  end

  test "RO-192 page.unroute should not wait for pending handlers to complete", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()

    Page.route!(page, ~r/.*/, fn route ->
      send(me, :second_handler_called)
      Route.continue!(route)
    end)

    handler = fn route ->
      send(me, {:route_callback, self()})
      await_barrier(page)
      Route.fallback!(route)
    end

    Page.route!(page, ~r/.*/, handler)
    navigation_promise = Runtime.Promise.async(fn -> Page.goto!(page, server.empty_page) end)
    assert_receive {:route_callback, handler_pid}, 5000
    Page.unroute!(page, ~r/.*/, handler)
    send(handler_pid, :continue)
    Runtime.Promise.await(navigation_promise)
    assert_received :second_handler_called
  end

  test "RO-193 page.unrouteAll removes all routes", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    Page.route!(page, "**/*", &Route.abort/1)
    Page.route!(page, "**/empty.html", &Route.abort/1)
    Page.unroute_all!(page)
    response = Page.goto!(page, server.empty_page)
    assert Response.ok(response) == true
  end

  test "RO-194 page.unrouteAll should wait for pending handlers to complete", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()

    Page.route!(page, ~r/.*/, fn route ->
      send(me, :second_handler_called)
      Route.abort!(route)
    end)

    handler = fn route ->
      send(me, {:route_callback, self()})
      await_barrier(page)
      Route.fallback!(route)
    end

    Page.route!(page, ~r/.*/, handler)
    navigation_promise = Runtime.Promise.async(fn -> Page.goto!(page, server.empty_page) end)
    assert_receive {:route_callback, handler_pid}, 5000
    unroute_promise = Runtime.Promise.async(fn -> Page.unroute_all!(page, behavior: :wait) end, shared: true)
    Process.sleep(500)
    refute Runtime.Promise.settled?(unroute_promise)
    send(handler_pid, :continue)
    Runtime.Promise.await(unroute_promise)
    Runtime.Promise.await(navigation_promise)
    refute_received :second_handler_called
  end

  test "RO-195 page.unrouteAll should not wait for pending handlers to complete if behavior is ignoreErrors",
       %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()

    Page.route!(page, ~r/.*/, fn route ->
      send(me, :second_handler_called)
      Route.abort!(route)
    end)

    handler = fn _route ->
      send(me, {:route_callback, self()})
      await_barrier(page)
      raise "Handler error"
    end

    Page.route!(page, ~r/.*/, handler)
    navigation_promise = Runtime.Promise.async(fn -> Page.goto(page, server.empty_page) end)
    assert_receive {:route_callback, handler_pid}, 5000
    unroute_promise = Runtime.Promise.async(fn -> Page.unroute_all!(page, behavior: :ignore_errors) end, shared: true)
    Process.sleep(500)
    Runtime.Promise.await(unroute_promise)
    send(handler_pid, :continue)
    Runtime.Promise.await(navigation_promise)
    # The error in the unrouted handler should be silently caught.
    refute_received :second_handler_called
  end

  test "RO-196 page.close does not wait for active route handlers", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()
    Page.route!(page, ~r/.*/, fn _route -> send(me, :second_handler_called) end)

    Page.route!(page, ~r/.*/, fn _route ->
      send(me, :route_callback)
      await_forever(page)
    end)

    Runtime.Promise.void(fn -> Page.goto(page, server.empty_page) end)
    assert_receive :route_callback, 5000
    Page.close!(page)
    Process.sleep(500)
    refute_received :second_handler_called
  end

  test "RO-197 route.continue should not throw if page has been closed", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()
    Page.route!(page, ~r/.*/, fn route -> send(me, {:route_callback, route}) end)
    Runtime.Promise.void(fn -> Page.goto(page, server.empty_page) end)
    assert_receive {:route_callback, route}, 5000
    Page.close!(page)
    # Should not throw.
    Route.continue!(route)
    # Elixir only: the call lost its race with the closed page; its late result is no stray
    # message in this process (OTP runtime).
    Process.sleep(500)
    refute_received {:pw, _, _}
  end

  test "RO-198 route.fallback should not throw if page has been closed", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()
    Page.route!(page, ~r/.*/, fn route -> send(me, {:route_callback, route}) end)
    Runtime.Promise.void(fn -> Page.goto(page, server.empty_page) end)
    assert_receive {:route_callback, route}, 5000
    Page.close!(page)
    # Should not throw.
    Route.fallback!(route)
  end

  test "RO-199 route.fulfill should not throw if page has been closed", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/23781
    me = self()
    Page.route!(page, ~r/.*/, fn route -> send(me, {:route_callback, route}) end)
    Runtime.Promise.void(fn -> Page.goto(page, server.empty_page) end)
    assert_receive {:route_callback, route}, 5000
    Page.close!(page)
    # Should not throw.
    Route.fulfill!(route)
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43878' }
  test "RO-200 should not continue requests in flight (page)", %{page: page, server: server} do
    # A latch: the route handlers and the test await it.
    route_promise = Runtime.Promise.new(page)
    {:ok, started} = Agent.start_link(fn -> 0 end)
    Page.goto!(page, server.empty_page)

    Page.route!(page, "**/*", fn route ->
      if Agent.get_and_update(started, &{&1 + 1, &1 + 1}) == 2,
        do: Runtime.Promise.resolve(route_promise, nil)

      Runtime.Promise.await(route_promise)
      Page.wait_for_timeout!(page, if(String.ends_with?(Request.url(Route.request(route)), "/a"), do: 100, else: 1000))
      response = Route.fetch!(route)
      Route.fulfill!(route, response: response, body: "mocked")
    end)

    fetch_promise =
      Runtime.Promise.async(fn ->
        Page.evaluate!(page, "() => Promise.all(['/a', '/b'].map(async path => (await fetch(path)).text()))")
      end)

    Runtime.Promise.await(route_promise)
    Page.unroute_all!(page, behavior: :wait)
    bodies = Runtime.Promise.await(fetch_promise)
    assert bodies == ["mocked", "mocked"]
  end

  # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43878' }
  test "RO-201 should not continue requests in flight (context)", %{page: page, context: context, server: server} do
    # A latch: the route handlers and the test await it.
    route_promise = Runtime.Promise.new(page)
    {:ok, started} = Agent.start_link(fn -> 0 end)
    Page.goto!(page, server.empty_page)

    BrowserContext.route!(context, "**/*", fn route ->
      if Agent.get_and_update(started, &{&1 + 1, &1 + 1}) == 2,
        do: Runtime.Promise.resolve(route_promise, nil)

      Runtime.Promise.await(route_promise)
      Page.wait_for_timeout!(page, if(String.ends_with?(Request.url(Route.request(route)), "/a"), do: 100, else: 1000))
      response = Route.fetch!(route)
      Route.fulfill!(route, response: response, body: "mocked")
    end)

    fetch_promise =
      Runtime.Promise.async(fn ->
        Page.evaluate!(page, "() => Promise.all(['/a', '/b'].map(async path => (await fetch(path)).text()))")
      end)

    Runtime.Promise.await(route_promise)
    BrowserContext.unroute_all!(context, behavior: :wait)
    bodies = Runtime.Promise.await(fetch_promise)
    assert bodies == ["mocked", "mocked"]
  end
end
