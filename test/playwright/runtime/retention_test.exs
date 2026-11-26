defmodule Playwright.RetentionTest do
  # Not mirrored from upstream: a connection retains disposed objects in a FIFO capped by rows
  # (`Playwright.Runtime.Conn.retain/2`, `trim/2`). A driver of its own, so a test's small cap
  # doesn't evict other modules' objects; its tests run one at a time.
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserContext
  alias Playwright.BrowserType
  alias Playwright.Client.Browser, as: ClientBrowser
  alias Playwright.Client.ClientInstrumentation
  alias Playwright.Client.Connection
  alias Playwright.JSHandle
  alias Playwright.Page
  alias Playwright.Runtime.Conn
  alias Playwright.Runtime.Facade
  alias Playwright.Runtime.Heap
  alias Playwright.TargetClosedError
  alias Playwright.TestBrowser

  setup_all do
    name = __MODULE__.Driver
    start_supervised!({Playwright.Supervisor, name: name})
    browser_type = TestBrowser.browser_type(Playwright.instance(name))
    browser = BrowserType.launch!(browser_type, headless: TestBrowser.headless())
    %{browser: browser, browser_type: browser_type}
  end

  # The FIFO's cap for this connection, its entries `{seq, guid, rows}` oldest first, and its count.
  defp set_cap(%{conn: conn}, cap), do: Conn.run(conn, fn -> Process.put(:pw_max_retained_rows, cap) end)

  # Frees every entry of the FIFO.
  defp empty(browser) do
    set_cap(browser, 0)
    Conn.run(browser.conn, fn -> Conn.trim(browser.table, Conn.disposed_mark()) end)
    assert entries(browser) == []
  end

  defp real_cap(%{conn: conn}) do
    Conn.run(conn, fn ->
      Process.delete(:pw_max_retained_rows)
      Conn.max_retained_rows()
    end)
  end

  defp entries(%{table: table}),
    do: :ets.select(table, [{{{:connection, {:disposed, :"$1"}}, {:"$2", :"$3"}}, [], [{{:"$1", :"$2", :"$3"}}]}])

  defp retained_rows(%{conn: conn}), do: Conn.run(conn, fn -> Process.get(:pw_retained_rows, 0) end)

  # The rows of the FIFO's objects in the table (their markers'), and their entries'.
  defp table_rows(%{table: table} = browser),
    do:
      Enum.sum(for {_, guid, _} <- entries(browser), do: :ets.select_count(table, [{{{guid, :_}, :_}, [], [true]}]) + 1)

  defp seq(%{table: table, guid: guid}) do
    [{_, seq}] = :ets.lookup(table, {guid, :__retained__})
    seq
  end

  # The count is the sum of the entries' rows.
  defp assert_counted(browser),
    do: assert(retained_rows(browser) == Enum.sum(for {_, _, rows} <- entries(browser), do: rows))

  defp closed_context(browser) do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    BrowserContext.close!(context)
    {context, page}
  end

  test "the unit a dispose closes is retained by it, whatever the cap; the next dispose frees the older", %{
    browser: browser
  } do
    set_cap(browser, 1)
    {old_context, old_page} = closed_context(browser)
    # Over the cap by itself: its own dispose keeps it.
    assert Page.url(old_page) == "about:blank"
    assert BrowserContext.pages(old_context) == []

    {context, page} = closed_context(browser)
    assert Page.url(page) == "about:blank"
    assert Page.context(page) == context
    assert BrowserContext.browser(context) == browser
    # The FIFO holds this unit only, the context last.
    guids = for {_, guid, _} <- entries(browser), do: guid
    assert List.last(guids) == context.guid
    assert page.guid in guids
    refute old_context.guid in guids
    refute old_page.guid in guids
    assert_counted(browser)

    # The older unit is freed: reads raise, but the closed-state getters answer.
    assert_raise TargetClosedError, fn -> Page.url(old_page) end
    assert_raise TargetClosedError, fn -> BrowserContext.pages(old_context) end
    assert Page.is_closed(old_page)
    assert BrowserContext.is_closed(old_context)
  end

  # The driver disposes each page as it closes, and `close` disposes the context's `request`
  # first: kept with the open context, they are not freed by those disposes, so `_on_close`
  # still reads `request.tracing`.
  test "closing a context whose pages exceed the cap succeeds", %{browser: browser} do
    set_cap(browser, 1)
    test = self()
    context = Browser.new_context!(browser)
    pages = for _ <- 1..3, do: BrowserContext.new_page!(context)
    request = BrowserContext.request(context)
    BrowserContext.on(context, :close, fn _ -> send(test, {:readable, Heap.readable?(request)}) end)

    assert :ok = BrowserContext.close(context)
    assert_received {:readable, true}
    for page <- pages, do: assert(Page.url(page) == "about:blank")
    assert BrowserContext.pages(context) == []
  end

  test "children are queued before their parent, so a page is freed before its context", %{browser: browser} do
    set_cap(browser, 1_000_000)
    {context, page} = closed_context(browser)
    assert seq(page) < seq(context)
    {later_context, later_page} = closed_context(browser)

    # A cap that keeps all but the entries up to the first page: trimming frees just those.
    total = retained_rows(browser)
    freed = for {seq, _, rows} <- entries(browser), seq <= seq(page), do: rows
    set_cap(browser, total - Enum.sum(freed))
    Conn.run(browser.conn, fn -> Conn.trim(browser.table, Conn.disposed_mark()) end)

    assert_raise TargetClosedError, fn -> Page.url(page) end
    assert Page.is_closed(page)
    assert BrowserContext.pages(context) == []
    assert Page.url(later_page) == "about:blank"
    assert BrowserContext.pages(later_context) == []
    assert_counted(browser)
  end

  test "a long-lived process's closed contexts are bounded by the cap", %{browser: browser} do
    set_cap(browser, 1000)
    # Fill the FIFO to the cap first.
    for _ <- 1..10, do: closed_context(browser)
    before = Conn.stats(browser.conn).rows
    closed = for _ <- 1..20, do: closed_context(browser)

    # Within one unit (a context of one blank page, under 200 rows) of the cap.
    assert retained_rows(browser) < 1200
    assert abs(Conn.stats(browser.conn).rows - before) < 200
    assert_counted(browser)
    {context, page} = List.last(closed)
    assert Page.url(page) == "about:blank"
    assert BrowserContext.pages(context) == []
    {context, page} = hd(closed)
    assert_raise TargetClosedError, fn -> Page.url(page) end
    assert Page.is_closed(page)
    assert BrowserContext.is_closed(context)
  end

  test "an evicted browser is disconnected", %{browser: browser, browser_type: browser_type} do
    set_cap(browser, 1)
    other = BrowserType.launch!(browser_type, headless: TestBrowser.headless())
    BrowserContext.new_page!(Browser.new_context!(other))
    Browser.close!(other)
    assert Browser.browser_type(other) == browser_type
    closed_context(browser)

    assert_raise TargetClosedError, fn -> Browser.contexts(other) end
    refute Browser.is_connected(other)
  end

  # tests/library/browsercontext-reuse.spec.ts `reusedContext` (launch scenario).
  defp reused_context(browser) do
    Facade.call("browser._newContextForReuse", fn ->
      ClientBrowser._disconnect_from_reused_context(browser, "reusedContext")
      ClientBrowser._new_context_for_reuse(browser, %{})
    end)
  end

  test "an object created under a disposed one's guid drops its entry", %{browser: browser} do
    set_cap(browser, 1_000_000)
    context = reused_context(browser)
    page = BrowserContext.new_page!(context)
    # The same server context: a new object under the disposed one's guid.
    assert reused_context(browser).guid == context.guid

    # Alive again, under the same guid: no marker, no entry, not counted.
    guids = for {_, guid, _} <- entries(browser), do: guid
    refute context.guid in guids
    refute page.guid in guids
    refute Heap.retained?(context)
    assert Heap.alive?(context)
    assert_counted(browser)

    Facade.call(nil, fn -> ClientBrowser._disconnect_from_reused_context(browser, "reusedContext") end)
    assert context.guid in for({_, guid, _} <- entries(browser), do: guid)
    assert_counted(browser)
  end

  test "a process's closed contexts stay readable after it exits", %{browser: browser} do
    real_cap(browser)

    task =
      Task.async(fn ->
        context = Browser.new_context!(browser)
        page = BrowserContext.new_page!(context)
        Page.set_content!(page, "<p>closed</p>")
        BrowserContext.close!(context)
        {context, page}
      end)

    {context, page} = Task.await(task)
    ref = Process.monitor(task.pid)
    assert_receive {:DOWN, ^ref, :process, _, _}

    assert BrowserContext.browser(context) == browser
    assert Page.url(page) == "about:blank"
    assert Page.context(page) == context
  end

  # The real cap, filled with stand-in entries first: the contexts other processes close
  # meanwhile push the oldest out, not the context this process just closed.
  test "at the real cap, a context closed amid other processes' closes stays readable", %{browser: browser} do
    %{conn: conn, table: table} = browser
    empty(browser)
    cap = real_cap(browser)
    assert cap == 50_000

    fillers =
      Conn.run(conn, fn ->
        for i <- 1..div(cap, 100) do
          guid = "filler@#{System.unique_integer([:positive])}-#{i}"
          :ets.insert(table, for(n <- 1..99, do: {{guid, {:filler, n}}, n}))
          Conn.retain(table, guid)
          guid
        end
      end)

    churn = for _ <- 1..4, do: Task.async(fn -> for(_ <- 1..3, do: closed_context(browser)) end)
    {context, page} = closed_context(browser)
    closed = Enum.flat_map(churn, &Task.await(&1, 60_000))
    {last_context, _} = closed_context(browser)

    assert Page.url(page) == "about:blank"
    assert Page.context(page) == context
    assert BrowserContext.pages(context) == []
    assert BrowserContext.pages(last_context) == []
    for {context, _page} <- closed, do: assert(BrowserContext.browser(context) == browser)
    # The oldest stand-ins went, enough of them to stay within the cap and one close.
    refute :ets.member(table, {hd(fillers), :__retained__})
    assert :ets.member(table, {List.last(fillers), :__retained__})
    assert retained_rows(browser) < cap + 200
    assert_counted(browser)
    assert retained_rows(browser) == table_rows(browser)
  end

  # A close reads `_closedPromise` after its reply, which follows its context's dispose: a dispose
  # of another process's in between may free the context. The `close` call's `onApiCallEnd` runs
  # in between, in the closing process: another process closes its context there.
  test "a close returns when another process's dispose frees its context before it reads", %{browser: browser} do
    set_cap(browser, 1)
    context = Browser.new_context!(browser)
    BrowserContext.new_page!(context)
    other = Browser.new_context!(browser)
    instrumentation = Heap.get(context, :_instrumentation)
    test = self()

    listener = %{
      onApiCallEnd: fn _ ->
        if self() == test and Heap.retained?(context) and !Process.put(:other_closed, true) do
          Task.await(Task.async(fn -> BrowserContext.close!(other) end))
          send(test, {:freed, !Heap.readable?(context)})
        end
      end
    }

    ClientInstrumentation.add_listener(instrumentation, listener)
    on_exit(fn -> ClientInstrumentation.remove_listener(instrumentation, listener) end)

    assert :ok = BrowserContext.close(context)
    assert_received {:freed, true}
    assert BrowserContext.is_closed(context)
    assert BrowserContext.pages(other) == []
  end

  defp browser_with_contexts(browser_type) do
    other = BrowserType.launch!(browser_type, headless: TestBrowser.headless())

    contexts =
      for _ <- 1..3 do
        context = Browser.new_context!(other)
        {context, BrowserContext.new_page!(context)}
      end

    {other, contexts}
  end

  # The rows `obj` and its descendants (`_objects`) have in the table, with the marker and entry
  # each will get once retained.
  defp subtree_rows(%{table: table, guid: guid} = obj) do
    own = :ets.select_count(table, [{{{guid, :_}, :_}, [], [true]}]) + 2
    own + Enum.sum(for(child <- Heap.map_values(obj, :_objects), do: subtree_rows(child)))
  end

  # The driver disposes each context of a browser it closes, then the browser: each dispose trims
  # the oldest entries first, so the contexts stay while together they fit the cap.
  test "a browser's close keeps its contexts readable when they fit the cap, freeing older entries first", %{
    browser: browser,
    browser_type: browser_type
  } do
    %{conn: conn, table: table} = browser
    empty(browser)
    set_cap(browser, 1_000_000)
    {other, contexts} = browser_with_contexts(browser_type)
    # What the browser and its contexts will retain is at most their rows while open (a dispose
    # deletes rows: listeners, objects freed at once), plus the close's own few writes (its
    # reason, the closing status): 50 rows of room for those, and 10 for the newest filler, which
    # stays beside them.
    cap = subtree_rows(other) + 50 + 10

    # Older entries of 10 rows each (8 fields, the marker, the entry), more of them than the cap:
    # the oldest go whatever the browser retains, and the newest fits beside it.
    fillers =
      Conn.run(conn, fn ->
        for i <- 1..(div(cap, 10) + 5) do
          guid = "filler@#{System.unique_integer([:positive])}-#{i}"
          :ets.insert(table, for(n <- 1..8, do: {{guid, {:filler, n}}, n}))
          Conn.retain(table, guid)
          guid
        end
      end)

    set_cap(browser, cap)
    Browser.close!(other)

    for {context, page} <- contexts do
      assert Page.url(page) == "about:blank"
      assert BrowserContext.pages(context) == []
      assert BrowserContext.browser(context) == other
    end

    assert Browser.contexts(other) == []
    # The oldest fillers went, just enough of them to fit the cap.
    kept = Enum.map(fillers, &:ets.member(table, {&1, :__retained__}))
    assert Enum.sort(kept) == kept
    refute hd(kept)
    assert List.last(kept)
    assert retained_rows(browser) <= cap
    assert_counted(browser)
  end

  test "at a cap of one row, a browser's close keeps its last dispose's unit readable", %{
    browser: browser,
    browser_type: browser_type
  } do
    set_cap(browser, 1)
    {other, contexts} = browser_with_contexts(browser_type)
    Browser.close!(other)

    assert Browser.browser_type(other) == browser_type
    assert Browser.contexts(other) == []
    refute Browser.is_connected(other)

    for {context, page} <- contexts do
      assert_raise TargetClosedError, fn -> Page.url(page) end
      assert_raise TargetClosedError, fn -> BrowserContext.pages(context) end
      assert BrowserContext.is_closed(context)
    end

    assert_counted(browser)
  end

  # The driver's `__dispose__` with reason "gc" (simulated, as in `Playwright.RuntimeConnTest`).
  defp collect(%{conn: conn, guid: guid}) do
    connection = Conn.connection(conn)
    message = %{"guid" => guid, "method" => "__dispose__", "params" => %{"reason" => "gc"}}
    Conn.run(conn, fn -> Connection.dispatch(connection, message) end)
  end

  test "tombstones of collected objects are bounded by a count of their own, outside the row cap", %{browser: browser} do
    set_cap(browser, 1_000_000)
    Conn.run(browser.conn, fn -> Process.put(:pw_max_collected, 2) end)
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    handles = for _ <- 1..3, do: Page.evaluate_handle!(page, "() => ({})")
    {closed_context, closed_page} = closed_context(browser)
    # At the cap: one more retained row would free the closed context.
    set_cap(browser, retained_rows(browser))

    for handle <- handles, do: collect(handle)

    assert Page.url(closed_page) == "about:blank"
    assert BrowserContext.pages(closed_context) == []
    assert_counted(browser)
    # The two newest raise upstream's error; the oldest's tombstone went.
    for handle <- tl(handles) do
      assert {:error, e} = JSHandle.json_value(handle)
      assert e.message =~ "The object has been collected to prevent unbounded heap growth."
    end

    assert {:error, %TargetClosedError{}} = JSHandle.json_value(hd(handles))
    entries = :ets.select(browser.table, [{{{:connection, {:collected, :_}}, :"$1"}, [], [:"$1"]}])
    assert entries == Enum.map(tl(handles), & &1.guid)
    BrowserContext.close!(context)
  after
    Conn.run(browser.conn, fn -> Process.delete(:pw_max_collected) end)
  end

  # A retained object loses rows (a latch `Promise.free/1` frees; here deleted directly): the
  # trim counts the oldest entry's rows again before it frees it.
  test "the trim recounts an entry's rows before it frees it", %{browser: browser} do
    empty(browser)
    set_cap(browser, 1_000_000)
    closed_context(browser)
    [{seq, guid, _} | _] = entries = entries(browser)
    fields = :ets.select(browser.table, [{{{guid, :"$1"}, :_}, [{:"=/=", :"$1", :__retained__}], [:"$1"]}])
    assert fields != []
    Conn.run(browser.conn, fn -> :ets.delete(browser.table, {guid, hd(fields)}) end)

    # Over the cap by the counted rows, not by the table's.
    set_cap(browser, retained_rows(browser) - 1)
    Conn.run(browser.conn, fn -> Conn.trim(browser.table, Conn.disposed_mark()) end)

    assert [{^seq, ^guid, _} | _] = entries(browser)
    assert length(entries(browser)) == length(entries)
    assert_counted(browser)
    assert retained_rows(browser) == table_rows(browser)
  end
end
