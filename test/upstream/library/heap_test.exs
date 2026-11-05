defmodule PlaywrightEx.Library.HeapTest do
  @upstream "tests/library/heap.spec.ts"
  # test.describe.configure({ mode: 'serial' })
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Page

  # queryObjectCount (node:inspector Runtime.queryObjects on this process' V8 heap) and the
  # beforeAll that records client classes  -- not ported: in-process heap inspection

  # for (let i = 0; i < 3; ++i) test(`test #${i} to request page and context`)  -- names built at runtime
  for i <- 0..2 do
    @tag :page
    test "test ##{i} to request page and context", %{page: _page, context: _context} do
      # This test is here to create page instance
    end
  end

  @tag :page
  test "test to request page and context", %{page: _page, context: _context} do
    # This test is here to create page instance
  end

  @tag skip: "not ported: queryObjectCount (in-process V8 heap inspection)"
  test "should not leak fixtures w/ page"

  @tag skip: "not ported: queryObjectCount (in-process V8 heap inspection)"
  test "should not leak fixtures w/o page"

  @tag skip: "not ported: queryObjectCount (in-process V8 heap inspection)"
  test "should not leak server-side objects"

  @tag skip: "not ported: queryObjectCount (in-process V8 heap inspection)"
  test "should not leak dispatchers after closing page"

  @tag skip: "not ported: queryObjectCount (in-process V8 heap inspection)"
  test "should not leak workers"

  # test.describe(() => { ... })
  # test.beforeEach/afterEach: coreServer.setMaxDispatchersForTest(100 / null)  -- not ported:
  # in-process server internals (the driver runs with its default limit)

  @tag skip: "not ported: coreServer.setMaxDispatchersForTest, queryObjectCount (in-process server internals)"
  test "should collect stale handles"

  @tag :page
  @tag timeout: 300_000
  test "should collect frames", %{page: page, server: server} do
    k_frame_count = 310

    Page.goto!(page, server.empty_page)
    me = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Page.on(page, :frame_attached, fn _frame ->
      # Make sure we can access page.
      Page.title!(page)
      if Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) == k_frame_count, do: send(me, :done)
    end)

    Task.start(fn ->
      Page.evaluate(
        page,
        """
        async ({ url, count }) => {
          for (let i = 0; i < count; i++) {
            const frame = document.createElement('iframe');
            frame.src = url;
            document.body.appendChild(frame);
            await new Promise(f => window.builtins.setTimeout(f, 10));
            frame.remove();
          }
        }
        """,
        %{url: server.prefix <> "/one-style.html", count: k_frame_count}
      )
    end)

    assert_receive :done, 120_000
    Page.wait_for_timeout!(page, 500)
  end

  @tag :page
  test "cycle handles", %{page: page, server: server} do
    # test.skip(trace === 'on')  -- tracing is off
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, String.duplicate("<div><span>hi</span></div>", 2000))
    divs = Page.query_selector_all!(page, "div")

    for div <- divs do
      span = ElementHandle.query_selector!(div, "span")
      assert ElementHandle.text_content!(span) == "hi"
    end
  end
end
