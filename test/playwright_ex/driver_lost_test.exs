defmodule PlaywrightEx.DriverLostTest do
  # A lost driver emulates the close of every page, context and browser, as `BrowserType.connect`
  # does on a lost connection (`PlaywrightEx.OutOfProcess`), and `PlaywrightEx.playwright/1`
  # returns the restarted driver's root. The loss is logged once; handles of the lost driver read
  # their last state while their creators (and the supervisor) live.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.TargetClosedError
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.Transport.Pipe
  alias PlaywrightEx.Worker

  @moduletag :tmp_dir
  # Losing the driver logs an error.
  @moduletag :capture_log

  test "kill -9 of the driver", %{tmp_dir: tmp_dir} do
    log = lose_driver(__MODULE__.Kill, tmp_dir, &kill_driver/1)
    assert_lost_logged(log, __MODULE__.Kill, "exit status 137: SIGKILL, often out of memory")
  end

  test "the driver's pipe closed", %{tmp_dir: tmp_dir} do
    log = lose_driver(__MODULE__.PipeClose, tmp_dir, &Pipe.close/1)
    assert_lost_logged(log, __MODULE__.PipeClose, "its pipe was closed")
  end

  test "a normal stop logs no loss" do
    name = __MODULE__.Stop

    log =
      capture_log(fn ->
        start_supervised!({PlaywrightEx.Supervisor, name: name})
        BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright(name)))
        stop_supervised!(name)
      end)

    refute log =~ "Playwright driver lost"
  end

  # One line, with the cause and the browsers and contexts closed (CDP: the server and the
  # connected browser, with its default context).
  defp assert_lost_logged(log, name, cause) do
    {browsers, contexts} = if TestBrowser.name() == "chromium", do: {4, 3}, else: {2, 2}

    assert [line] = log |> String.split("\n") |> Enum.filter(&(&1 =~ "supervisor #{inspect(name)},"))

    assert line =~
             "[error] Playwright driver lost (#{cause}): driver #{PlaywrightEx.Driver.version()}, " <>
               "supervisor #{inspect(name)}, #{browsers} browsers and #{contexts} contexts closed; " <>
               "starting a new driver"
  end

  # Returns the log.
  defp lose_driver(name, tmp_dir, lose) do
    {_, log} = with_log(fn -> do_lose_driver(name, tmp_dir, lose) end)
    log
  end

  defp do_lose_driver(name, tmp_dir, lose) do
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    playwright = PlaywrightEx.playwright(name)
    oop = Process.monitor(Process.whereis(PlaywrightEx.Supervisor.out_of_process(name)))
    browser_type = TestBrowser.browser_type(playwright)
    test = self()

    browser = BrowserType.launch!(browser_type)
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    persistent = BrowserType.launch_persistent_context!(browser_type, tmp_dir)
    persistent_page = BrowserContext.new_page!(persistent)
    persistent_browser = BrowserContext.browser(persistent)

    # Connected over CDP on the local connection: its default context and page close too.
    cdp =
      if TestBrowser.name() == "chromium" do
        port = free_port()
        server = BrowserType.launch!(browser_type, args: ["--remote-debugging-port=#{port}"])
        cdp_browser = BrowserType.connect_over_cdp!(browser_type, "http://127.0.0.1:#{port}/")
        [cdp_context] = Browser.contexts(cdp_browser)
        cdp_page = BrowserContext.new_page!(cdp_context)
        %{server: server, browser: cdp_browser, context: cdp_context, page: cdp_page}
      end

    event = fn tag -> fn _ -> send(test, {:event, tag}) end end
    on_page_close = event.(:page)
    Page.on(page, :close, on_page_close)
    BrowserContext.on(context, :close, event.(:context))
    Page.on(persistent_page, :close, event.(:persistent_page))
    BrowserContext.on(persistent, :close, event.(:persistent))
    Browser.on(persistent_browser, :disconnected, event.(:persistent_browser))

    if cdp do
      Browser.on(cdp.server, :disconnected, event.(:cdp_server))
      Page.on(cdp.page, :close, event.(:cdp_page))
      BrowserContext.on(cdp.context, :close, event.(:cdp_context))
      Browser.on(cdp.browser, :disconnected, event.(:cdp_browser))
    end

    # The last listener of `browser`: the closed state is readable, and the root of the restarted
    # driver works (the old connection stops once this listener awaits).
    Browser.on(browser, :disconnected, fn _ ->
      send(test, {:event, :browser})
      send(test, {:state, Browser.is_connected(browser), Page.is_closed(page), BrowserContext.pages(context)})
      new = PlaywrightEx.playwright(name)
      new_browser = BrowserType.launch!(TestBrowser.browser_type(new))
      result = Page.evaluate!(Browser.new_page!(new_browser), "1 + 1")
      Browser.close!(new_browser)
      send(test, {:relaunched, new != playwright, result})
    end)

    # A worker is not closed by the emulation: its wait rejects when the connection process exits.
    worker =
      Page.expect_event!(page, :worker, fn ->
        Page.evaluate!(
          page,
          "() => new Worker(URL.createObjectURL(new Blob(['1'], { type: 'application/javascript' })))"
        )
      end)

    # In-flight waits (no timeout, a timeout, a context's, a worker's).
    waits = [
      Page.wait_for_event(page, :popup, timeout: 0),
      Page.wait_for_event(persistent_page, :popup),
      BrowserContext.wait_for_event(context, :page, timeout: 0),
      Worker.wait_for_event(worker, :console, timeout: 0)
    ]

    # The last URL, read after the loss.
    Page.goto!(page, "about:blank#last")
    lose.(Heap.get(playwright, :driverProcess))

    # Pages and contexts close (in creation order), then the browsers.
    expected =
      if cdp,
        do:
          ~w(page context persistent_page persistent cdp_page cdp_context browser persistent_browser cdp_server cdp_browser)a,
        else: ~w(page context persistent_page persistent browser persistent_browser)a

    assert events(length(expected)) == expected

    # Right after `disconnected`: the restarted driver's root.
    new = PlaywrightEx.playwright(name)
    assert new != playwright
    new_browser = BrowserType.launch!(TestBrowser.browser_type(new))
    assert Page.evaluate!(Browser.new_page!(new_browser), "2 + 2") == 4
    Browser.close!(new_browser)

    assert_receive {:state, false, true, []}
    assert_receive {:relaunched, true, 2}

    for wait <- waits, do: assert({:error, %TargetClosedError{}} = PlaywrightEx.Promise.await(wait))

    # Once each.
    assert_receive {:DOWN, ^oop, :process, _, {:shutdown, :driver_closed}}
    refute_received {:event, _}

    # After the old connection stopped, its handles read their last state.
    refute Process.alive?(page.conn)
    refute Browser.is_connected(browser)
    assert Page.is_closed(page)
    assert BrowserContext.pages(context) == []
    assert Browser.contexts(browser) == []
    assert BrowserContext.is_closed(context)
    assert Page.url(page) == "about:blank#last"
    assert Page.context(page) == context
    assert BrowserContext.browser(context) == browser
    assert is_binary(Browser.version(browser))
    assert BrowserContext.pages(persistent) == []
    refute Browser.is_connected(persistent_browser)
    # Calls reject, writes raise.
    assert {:error, %TargetClosedError{}} = Page.title(page)
    assert {:error, %TargetClosedError{}} = Page.goto(page, "about:blank")
    assert {:error, %TargetClosedError{}} = PlaywrightEx.Promise.await(Page.wait_for_event(page, :close))
    assert_raise TargetClosedError, fn -> Page.set_default_timeout(page, 1000) end
    assert_raise TargetClosedError, fn -> Page.on(page, :close, fn _ -> :ok end) end
    # As in JS: removing a listener never raises.
    assert Page.off(page, :close, on_page_close) == page
    assert Page.remove_listener(page, :close, fn _ -> :ok end) == page
    # As in JS: closing what is closed returns.
    assert Page.close!(page) == :ok
    assert BrowserContext.close!(context) == :ok
    assert Browser.close!(browser) == :ok
    assert Page.close(persistent_page) == :ok
    assert BrowserContext.close(persistent) == :ok
    assert Browser.close(persistent_browser) == :ok
    if cdp, do: assert(Browser.close!(cdp.browser) == :ok)
  end

  test "the table of a lost driver goes once its creators have exited" do
    name = __MODULE__.Creators
    start_supervised!({PlaywrightEx.Supervisor, name: name})
    playwright = PlaywrightEx.playwright(name)
    test = self()

    creator =
      spawn(fn ->
        browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
        page = Browser.new_page!(browser)
        Browser.on(browser, :disconnected, fn _ -> send(test, :disconnected) end)
        send(test, {:page, page})
        receive do: (:exit -> :ok)
      end)

    assert_receive {:page, page}, 10_000
    kill_driver(Heap.get(playwright, :driverProcess))
    assert_receive :disconnected, 5_000
    [keeper] = wait_for_keeper(page)
    assert Page.is_closed(page)
    ref = Process.monitor(keeper)
    send(creator, :exit)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert_raise TargetClosedError, fn -> Page.is_closed(page) end
    assert Page.off(page, :close, fn _ -> :ok end) == page
  end

  test "the table of a lost driver goes with the supervisor" do
    goes_with_supervisor(__MODULE__.Lifeline, &stop_supervised!/1)
  end

  test "the table of a lost driver goes with a brutally killed supervisor" do
    goes_with_supervisor(__MODULE__.LifelineKill, &Process.exit(Process.whereis(&1), :kill))
  end

  defp goes_with_supervisor(name, stop) do
    start_supervised!({PlaywrightEx.Supervisor, name: name}, restart: :temporary)
    playwright = PlaywrightEx.playwright(name)
    browser = BrowserType.launch!(TestBrowser.browser_type(playwright))
    page = Browser.new_page!(browser)
    test = self()
    Browser.on(browser, :disconnected, fn _ -> send(test, :disconnected) end)
    kill_driver(Heap.get(playwright, :driverProcess))
    assert_receive :disconnected, 5_000
    [keeper] = wait_for_keeper(page)
    assert Page.is_closed(page)
    ref = Process.monitor(keeper)
    stop.(name)
    assert_receive {:DOWN, ^ref, :process, _, _}
    assert_raise TargetClosedError, fn -> Page.is_closed(page) end
  end

  # The table's owner once the connection process stopped.
  defp wait_for_keeper(%{conn: conn, table: table}) do
    ref = Process.monitor(conn)
    assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
    [:ets.info(table, :owner)]
  end

  defp kill_driver(transport) do
    %{port: port} = :sys.get_state(transport)
    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {_, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
  end

  defp events(0), do: []

  defp events(n) do
    assert_receive {:event, tag}
    [tag | events(n - 1)]
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end
