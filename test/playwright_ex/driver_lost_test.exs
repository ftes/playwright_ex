defmodule PlaywrightEx.DriverLostTest do
  # A lost driver emulates the close of every page, context and browser, as `BrowserType.connect`
  # does on a lost connection (`PlaywrightEx.OutOfProcess`), and `PlaywrightEx.playwright/1`
  # returns the restarted driver's root.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.TargetClosedError
  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.Transport.Pipe

  @moduletag :tmp_dir

  test "kill -9 of the driver", %{tmp_dir: tmp_dir} do
    lose_driver(__MODULE__.Kill, tmp_dir, fn transport ->
      %{port: port} = :sys.get_state(transport)
      {:os_pid, os_pid} = Port.info(port, :os_pid)
      {_, 0} = System.cmd("kill", ["-9", to_string(os_pid)])
    end)
  end

  test "the driver's pipe closed", %{tmp_dir: tmp_dir} do
    lose_driver(__MODULE__.PipeClose, tmp_dir, &Pipe.close/1)
  end

  defp lose_driver(name, tmp_dir, lose) do
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
    Page.on(page, :close, event.(:page))
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

    # In-flight waits (no timeout, a timeout, a context's).
    waits = [
      Page.wait_for_event(page, :popup, timeout: 0),
      Page.wait_for_event(persistent_page, :popup),
      BrowserContext.wait_for_event(context, :page, timeout: 0)
    ]

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
