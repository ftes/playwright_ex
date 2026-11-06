defmodule PlaywrightEx.RuntimeStressTest do
  # Stress tests of the OTP runtime (PLAN Phase 2): each scenario loops 100 times and checks the
  # exact order (JS's), an empty mailbox (no stray `{:pw, _, _}`) and no orphan processes. Manual
  # only (`mix test --only stress`; excluded by default, not run by CI).
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime.Conn
  alias PlaywrightEx.Runtime.Facade

  @moduletag :stress
  @moduletag :page

  @iterations 100

  # 1. Listeners for events the driver sends before a call's reply have run when the call returns.
  @tag timeout: 60_000
  test "event-before-reply: console, request and framenavigated before evaluate/goto return", %{
    page: page,
    server: server
  } do
    test = self()
    Page.goto!(page, server.empty_page)
    baseline = baseline(page)
    # Some work in the listeners, so a gap would show.
    work = fn -> Enum.sum(1..20_000) end

    report = fn event, value ->
      work.()
      send(test, {event, value})
    end

    # Firefox also logs a quirks mode warning.
    Page.on(page, :console, fn m ->
      if ConsoleMessage.type(m) == "log", do: report.(:console, ConsoleMessage.text(m))
    end)

    Page.on(page, :request, fn r -> if Request.url(r) =~ "empty.html", do: report.(:request, Request.url(r)) end)
    Page.on(page, :frame_navigated, &report.(:frame_navigated, Frame.url(&1)))

    for i <- 1..@iterations do
      url = server.empty_page <> "?i=#{i}"
      Page.goto!(page, url)
      assert {i, take()} == {i, [{:request, url}, {:frame_navigated, url}]}
      Page.evaluate!(page, "i => { console.log('a' + i); console.log('b' + i); }", i)
      assert {i, take()} == {i, [{:console, "a#{i}"}, {:console, "b#{i}"}]}
    end

    Page.remove_all_listeners!(page)
    assert_clean(page, baseline)
  end

  # 2. Registration order, prepend first; `once` fires exactly once under back-to-back emits.
  @tag timeout: 60_000
  test "listener order and once", %{page: page} do
    test = self()
    baseline = baseline(page)
    listener = fn name -> fn m -> send(test, {name, ConsoleMessage.text(m)}) end end

    for i <- 1..@iterations do
      Page.on(page, :console, listener.(:a))
      Page.once(page, :console, listener.(:once1))
      Page.prepend_listener(page, :console, listener.(:pre))
      Page.on(page, :console, listener.(:b))
      Page.once(page, :console, listener.(:once2))
      Page.evaluate!(page, "() => { console.log('x'); console.log('y'); console.log('z'); }")

      expected =
        Enum.map([:pre, :a, :once1, :b, :once2], &{&1, "x"}) ++
          Enum.map([:pre, :a, :b], &{&1, "y"}) ++ Enum.map([:pre, :a, :b], &{&1, "z"})

      assert {i, take()} == {i, expected}
      Page.remove_all_listeners!(page, :console)
    end

    assert_clean(page, baseline)
  end

  # 3. A route handler calling page API, which calls a binding that calls evaluate; a locator
  # handler calling click.
  @tag timeout: 60_000
  test "re-entrant handlers: route, binding, locator handler", %{page: page, server: server} do
    test = self()
    Page.goto!(page, server.empty_page)
    baseline = baseline(page)

    Page.expose_binding!(page, "stressBinding", fn _source, x ->
      send(test, {:binding, x})
      Page.evaluate!(page, "x => x * 2", x)
    end)

    Page.route!(page, "**/data*", fn route, request ->
      "i=" <> i = URI.parse(Request.url(request)).query
      send(test, {:route, i, Page.title!(page)})
      doubled = Page.evaluate!(page, "i => window.stressBinding(i)", String.to_integer(i))
      Route.fulfill!(route, body: "#{doubled}", content_type: "text/plain")
      send(test, {:route_done, i})
    end)

    Page.add_locator_handler!(page, Page.locator(page, "#overlay"), fn _overlay ->
      send(test, :handler)
      Locator.click!(Page.locator(page, "#close"))
      send(test, :handler_done)
    end)

    for i <- 1..@iterations do
      Page.set_content!(page, """
      <title>t#{i}</title>
      <button id="target" onclick="window.clicked = #{i}">target</button>
      <div id="overlay" style="position: fixed; inset: 0; background: red">
        <button id="close" onclick="document.querySelector('#overlay').remove()">close</button>
      </div>
      """)

      assert Page.evaluate!(page, "i => fetch('/data?i=' + i).then(r => r.text())", i) == "#{2 * i}"
      Locator.click!(Page.locator(page, "#target"))
      assert Page.evaluate!(page, "window.clicked") == i

      assert {i, take()} ==
               {i, [{:route, "#{i}", "t#{i}"}, {:binding, i}, {:route_done, "#{i}"}, :handler, :handler_done]}
    end

    Page.unroute_all!(page)
    Page.remove_all_listeners!(page)
    assert_clean(page, baseline)
  end

  # 4. An emit from a listener runs its listeners before the emitting listener continues (JS:
  # `emit` is synchronous), depth first, from a dispatched event and from a plain process.
  @tag timeout: 60_000
  test "nested emit order", %{page: page} do
    test = self()
    baseline = baseline(page)

    on = fn type, fun -> Facade.listen(fn -> PlaywrightEx.Client.Page.on(page, type, fun) end) end
    Page.on(page, :console, fn m -> nested(test, page, :l1, ConsoleMessage.text(m), "stressNested") end)
    Page.on(page, :console, fn m -> send(test, {:l2, ConsoleMessage.text(m)}) end)
    on.("stressNested", fn arg -> nested(test, page, :n1, arg, "stressDeep") end)
    on.("stressNested", fn arg -> send(test, {:n2, arg}) end)
    on.("stressDeep", fn arg -> send(test, {:d1, arg}) end)

    for i <- 1..@iterations do
      Page.evaluate!(page, "i => { console.log('c' + i); console.log('e' + i); }", i)
      c = "c#{i}"
      e = "e#{i}"

      assert {i, take()} ==
               {i,
                [
                  {:l1, :start, c},
                  {:n1, :start, c},
                  {:d1, c},
                  {:n1, :end, c},
                  {:n2, c},
                  {:l1, :end, c},
                  {:l2, c},
                  {:l1, :start, e},
                  {:n1, :start, e},
                  {:d1, e},
                  {:n1, :end, e},
                  {:n2, e},
                  {:l1, :end, e},
                  {:l2, e}
                ]}

      # From a process outside dispatch: emit returns after the listeners ran.
      EventEmitter.emit(page, "stressNested", "t#{i}")
      assert {i, take()} == {i, [{:n1, :start, "t#{i}"}, {:d1, "t#{i}"}, {:n1, :end, "t#{i}"}, {:n2, "t#{i}"}]}
    end

    Page.remove_all_listeners!(page)
    assert_clean(page, baseline)
  end

  defp nested(test, page, name, arg, type) do
    send(test, {name, :start, arg})
    EventEmitter.emit(page, type, arg)
    send(test, {name, :end, arg})
  end

  # 5. Many processes calling one page; a latch awaited from many processes.
  @tag timeout: 120_000
  test "concurrent callers on one page", %{page: page} do
    baseline = baseline(page)

    for i <- 1..@iterations do
      results =
        1..20
        |> Enum.map(fn p ->
          Task.async(fn -> for c <- 1..5, do: Page.evaluate!(page, "([p, c]) => p * 10 + c", [p, c]) end)
        end)
        |> Task.await_many(20_000)

      assert {i, results} == {i, for(p <- 1..20, do: for(c <- 1..5, do: p * 10 + c))}

      latch = Page.wait_for_event(page, :console)
      awaiters = for _ <- 1..20, do: Task.async(fn -> ConsoleMessage.text(Promise.await!(latch)) end)
      Page.evaluate!(page, "i => console.log('l' + i)", i)
      assert {i, Task.await_many(awaiters, 20_000)} == {i, List.duplicate("l#{i}", 20)}
      assert ConsoleMessage.text(Promise.await!(latch)) == "l#{i}"
    end

    assert_clean(page, baseline)
  end

  # 6. connect, closing page, context and browser in every order: `disconnected` exactly once, no
  # leaked Conn processes or ETS tables.
  @tag timeout: 300_000
  test "connect: nested close in permuted orders", %{
    browser_type: browser_type,
    page: page,
    start_remote_server: start_remote_server
  } do
    server = start_remote_server.("launchServer", %{})
    endpoint = PlaywrightEx.RemoteServer.ws_endpoint(server)
    test = self()

    orders = permutations([:page, :context, :browser])

    cycle = fn i ->
      browser = BrowserType.connect!(browser_type, endpoint)
      Browser.on(browser, :disconnected, fn _ -> send(test, {:disconnected, i}) end)
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      Page.on(page, :close, fn _ -> send(test, {:page_close, i}) end)
      BrowserContext.on(context, :close, fn _ -> send(test, {:context_close, i}) end)
      objects = %{page: page, context: context, browser: browser}

      for kind <- Enum.at(orders, rem(i, length(orders))) do
        case kind do
          :page -> Page.close!(objects.page)
          :context -> BrowserContext.close!(objects.context)
          :browser -> Browser.close!(objects.browser)
        end
      end

      refute Browser.is_connected(browser)
    end

    # Warm up (the first connect creates objects of the local connection).
    Task.await(Task.async(fn -> cycle.(0) end), 30_000)
    assert eventually(fn -> conns(browser_type) == [] end)
    take()
    before = counts(browser_type)
    rows = :ets.info(browser_type.table, :size)
    baseline = baseline(page)

    for i <- 1..@iterations do
      Task.await(Task.async(fn -> cycle.(i) end), 30_000)
      assert_receive {:disconnected, ^i}
      Process.sleep(10)
      events = [{:disconnected, i} | take()]
      # Each close event once; their order depends on the close order (as in JS).
      assert Enum.sort(events) == Enum.sort([{:disconnected, i}, {:page_close, i}, {:context_close, i}]),
             "iteration #{i} (#{inspect(Enum.at(orders, rem(i, length(orders))))}): #{inspect(events)}"
    end

    Process.sleep(100)
    assert take() == []
    no_growth = fn -> Enum.all?(counts(browser_type), fn {key, count} -> count <= before[key] end) end
    assert eventually(no_growth), "#{inspect(before)} -> #{inspect(counts(browser_type))}"
    assert :ets.info(browser_type.table, :size) - rows <= 10
    assert_clean(page, baseline)
  end

  # Minimized from scenario 6. JS: `browser.close()` awaits `_closedPromise`, resolved by a `once`
  # listener in the same synchronous `emit` that runs the user's listeners, so they have run when
  # close returns. Here the latch's wake-up is held until the emit's steps have run
  # (`Runtime.Conn.wake/2`); waking the awaiter at the latch's step failed every run.
  test "connect: the disconnected listener has run when close returns", %{
    browser_type: browser_type,
    start_remote_server: start_remote_server
  } do
    test = self()
    server = start_remote_server.("launchServer", %{})
    endpoint = PlaywrightEx.RemoteServer.ws_endpoint(server)

    for i <- 1..20 do
      browser = BrowserType.connect!(browser_type, endpoint)
      Browser.on(browser, :disconnected, fn _ -> send(test, {:disconnected, i}) end)
      Browser.close!(browser)
      assert_received {:disconnected, ^i}
    end
  end

  # 7. A wait started by one process, aborted from a third: always rejected with the reason,
  # whether the abort comes before, during or after the wait starts.
  @tag timeout: 60_000
  test "AbortController aborted from a third process", %{page: page} do
    test = self()
    baseline = baseline(page)

    for i <- 1..@iterations do
      controller = AbortController.new()
      signal = AbortController.signal(controller)

      waiter =
        spawn(fn ->
          receive do: (:go -> :ok)

          result =
            try do
              Page.wait_for_event!(page, :popup, signal: signal, timeout: 0)
            rescue
              e -> e
            end

          send(test, {:waited, i, result})
        end)

      aborter =
        spawn(fn ->
          receive do: (:go -> :ok)
          # Before, around and after the waiter subscribes.
          if rem(i, 3) == 1, do: Process.sleep(5)
          AbortController.abort(controller, "stop #{i}")
          send(test, {:aborted, i})
        end)

      if rem(i, 3) == 0 do
        send(aborter, :go)
        assert_receive {:aborted, ^i}
        send(waiter, :go)
      else
        send(waiter, :go)
        send(aborter, :go)
        assert_receive {:aborted, ^i}
      end

      assert_receive {:waited, ^i, %PlaywrightEx.AbortError{} = error}, 5000
      assert error.cause == "stop #{i}"
      assert error.message =~ "page.waitForEvent: The operation was aborted"
    end

    assert_clean(page, baseline)
  end

  ## Helpers

  # The messages in the mailbox, removed.
  defp take(acc \\ []) do
    receive do
      message -> take([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # After a warm-up call: the processes and the page connection's stats.
  defp baseline(page) do
    Page.evaluate!(page, "1")
    Process.sleep(50)
    %{processes: Process.list(), stats: Conn.stats(page.conn)}
  end

  # Empty mailbox, no new processes, no pending callbacks or listener processes on the connection.
  defp assert_clean(page, baseline) do
    Process.sleep(50)
    assert take() == []
    orphans = fn -> Enum.filter(Process.list() -- baseline.processes, &Process.alive?/1) end
    assert eventually(fn -> orphans.() == [] end), "orphans: #{inspect(Enum.map(orphans.(), &describe/1))}"
    stats = Conn.stats(page.conn)
    assert stats.callbacks == 0
    assert stats.processes <= baseline.stats.processes
    assert stats.subscriptions <= baseline.stats.subscriptions
    assert stats.frames == 0
  end

  defp describe(pid) do
    info = Process.info(pid, [:initial_call, :current_function, :dictionary])
    {pid, info[:initial_call], info[:current_function], get_in(info, [:dictionary, :"$initial_call"])}
  end

  defp eventually(fun, attempts \\ 60) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(x <- list, rest <- permutations(list -- [x]), do: [x | rest])

  # The connection processes linked to the local one (a remote connection's `Conn`).
  defp conns(%{conn: parent}) do
    {:links, links} = Process.info(parent, :links)
    for pid <- links, is_pid(pid), match?({Conn, :init, _}, :proc_lib.initial_call(pid)), do: pid
  end

  defp counts(%{conn: parent} = browser_type) do
    {:links, links} = Process.info(parent, :links)
    tables = Enum.count(:ets.all(), &(:ets.info(&1, :name) == :playwright_ex_conn))
    %{links: length(links), conns: length(conns(browser_type)), tables: tables}
  end
end
