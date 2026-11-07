defmodule PlaywrightEx.Library.CoverageTest do
  @upstream "tests/library/coverage.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Utils

  import PlaywrightEx.Utils, only: [parse_trace_coverage: 2]

  @moduletag :tmp_dir

  # it.skip(({ trace }) => trace === 'on', 'the tests start their own tracing');  -- the runner does not trace

  defp file_coverage(file, s0) do
    %{
      file => %{
        path: file,
        statementMap: %{"0" => %{start: %{line: 1, column: 0}, end: %{line: 1, column: 20}}},
        fnMap: %{},
        branchMap: %{},
        s: %{"0" => s0},
        f: %{},
        b: %{}
      }
    }
  end

  defp coverage_script(file, s0), do: "<script>window.__coverage__ = #{JSON.encode!(file_coverage(file, s0))}</script>"

  # context.tracing.start({ _coverage: true } as any): the facade rejects `_coverage`, call the client.
  defp start_coverage(context) do
    tracing = BrowserContext.tracing(context)
    Api.call("tracing.start", tracing, fn -> PlaywrightEx.Client.Tracing.start(tracing, %{_coverage: true}) end)
  end

  defp tracing(context), do: BrowserContext.tracing(context)

  test "CV-018 should collect istanbul coverage into the trace", %{browser: browser, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    start_coverage(context)

    page = BrowserContext.new_page!(context)
    Page.set_content!(page, coverage_script("a.js", 3))

    # Coverage of a closed page is collected automatically.
    page2 = BrowserContext.new_page!(context)
    Page.set_content!(page2, coverage_script("b.js", 2))
    Page.close!(page2)

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    data = parse_trace_coverage(trace_file, browser)
    assert data["a.js"]["s"]["0"] == 3
    assert data["b.js"]["s"]["0"] == 2
  end

  test "CV-019 should collect coverage per trace chunk", %{browser: browser, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)

    Page.set_content!(page, coverage_script("a.js", 5))
    trace_file1 = Path.join(tmp_dir, "trace1.zip")
    Tracing.stop_chunk!(tracing(context), path: trace_file1)

    Tracing.start_chunk!(tracing(context))
    Page.set_content!(page, coverage_script("b.js", 7))
    trace_file2 = Path.join(tmp_dir, "trace2.zip")
    Tracing.stop_chunk!(tracing(context), path: trace_file2)

    Tracing.stop!(tracing(context))
    BrowserContext.close!(context)

    data1 = parse_trace_coverage(trace_file1, browser)
    assert data1["a.js"]["s"]["0"] == 5
    assert data1["b.js"] == nil

    data2 = parse_trace_coverage(trace_file2, browser)
    assert data2["b.js"]["s"]["0"] == 7
    assert data2["a.js"] == nil
  end

  test "CV-020 should report maps once and counters incrementally", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    # Actions collect the counters on their own, so hit and collect in one evaluate.
    first =
      Page.evaluate!(
        page,
        """
        coverage => {
          window.__coverage__ = JSON.parse(coverage);
          return window.__pwCoverageTake().map(json => JSON.parse(json));
        }
        """,
        JSON.encode!(file_coverage("a.js", 3))
      )

    Utils.assert_truthy(hd(first)["data"]["a.js"]["statementMap"])
    assert hd(first)["data"]["a.js"]["s"] == %{"0" => 3}

    second =
      Page.evaluate!(page, """
      () => {
        window.__coverage__['a.js'].s['0'] += 2;
        return window.__pwCoverageTake().map(json => JSON.parse(json));
      }
      """)

    assert hd(second)["data"]["a.js"]["statementMap"] == nil
    assert hd(second)["data"]["a.js"]["s"] == %{"0" => 2}

    # Nothing was hit since the last report.
    assert Page.evaluate!(page, "() => window.__pwCoverageTake()") == []

    Tracing.stop!(tracing(context))
    BrowserContext.close!(context)
  end

  test "CV-021 should accumulate counters across pulls and keep never hit files", %{browser: browser, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, coverage_script("a.js", 0))
    Page.evaluate!(page, "() => window.__coverage__['a.js'].s['0'] += 4")
    Page.evaluate!(page, "() => window.__coverage__['a.js'].s['0'] += 3")

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    data = parse_trace_coverage(trace_file, browser)
    assert data["a.js"]["s"]["0"] == 7
    assert Map.keys(data["a.js"]["statementMap"]) == ["0"]
  end

  defp open_popup(page, server, file, s0) do
    popup =
      Page.expect_event!(page, :popup, fn ->
        Page.evaluate!(page, "url => window.__popup = window.open(url)", server.empty_page)
      end)

    Page.evaluate!(
      popup,
      "coverage => window.__coverage__ = JSON.parse(coverage)",
      JSON.encode!(file_coverage(file, s0))
    )

    popup
  end

  test "CV-022 should collect coverage of a page closed by in-page script", %{
    browser: browser,
    server: server,
    tmp_dir: tmp_dir
  } do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup = open_popup(page, server, "popup.js", 5)
    # An in-page close never reaches Playwright as page.close(), the counters
    # are preserved because the actions collect them as they go.
    close_promise = Page.wait_for_event(popup, :close)
    Page.evaluate!(popup, "() => setTimeout(() => window.close(), 0)")
    Promise.await!(close_promise)

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    data = parse_trace_coverage(trace_file, browser)
    assert data["popup.js"]["s"]["0"] == 5
  end

  test "CV-023 should not double count a stash picked up twice", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    # Emulate two documents picking up the same stash before either removes it.
    prefix = "__pwCoverage." <> context.guid <> "."

    Page.evaluate!(
      page,
      """
      ({ prefix, coverage }) => {
        const chunk = JSON.stringify({ id: 'stash-id', data: JSON.parse(coverage) });
        localStorage.setItem(prefix + 'one', chunk);
        localStorage.setItem(prefix + 'two', chunk);
      }
      """,
      %{prefix: prefix, coverage: JSON.encode!(file_coverage("stashed.js", 4))}
    )

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    data = parse_trace_coverage(trace_file, browser)
    assert data["stashed.js"]["s"]["0"] == 4
  end

  test "CV-024 should discard stashes of other sessions", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      """
      coverage => {
        localStorage.setItem('__pwCoverage.other-session.1', JSON.stringify({ id: 'other', data: JSON.parse(coverage) }));
      }
      """,
      JSON.encode!(file_coverage("stale.js", 7))
    )

    remaining =
      Page.evaluate!(page, "() => Object.keys(localStorage).filter(key => key.startsWith('__pwCoverage.'))")

    assert remaining == []

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    # The stale stash was the only coverage, so nothing was collected at all.
    assert parse_trace_coverage(trace_file, browser) == nil
  end

  test "CV-025 should collect coverage of an origin left without a page", %{
    browser: browser,
    server: server,
    tmp_dir: tmp_dir
  } do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    popup = open_popup(page, server, "popup.js", 0)

    Page.evaluate!(
      popup,
      """
      url => {
        window.__go = () => {
          window.__coverage__['popup.js'].s['0'] = 5;
          window.location.href = url;
        };
      }
      """,
      server.cross_process_prefix <> "/empty.html"
    )

    # The popup is hit and navigates away, leaving a stash behind. Triggered from
    # the opener, so that the pull after the action does not race the navigation.
    task = Task.async(fn -> Page.wait_for_url!(popup, server.cross_process_prefix <> "/empty.html") end)
    Page.evaluate!(page, "() => window.__popup.__go()")
    Task.await(task, :infinity)
    # Leave the origin of the stash without a page to relay it.
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    data = parse_trace_coverage(trace_file, browser)
    assert data["popup.js"]["s"]["0"] == 5
  end

  test "CV-026 should pull counters as the actions go", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, coverage_script("a.js", 3))
    # The counters are collected by the action itself, not only by the final flush.
    assert Page.evaluate!(page, "() => window.__coverage__['a.js'].s['0']") == 0

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    data = parse_trace_coverage(trace_file, browser)
    assert data["a.js"]["s"]["0"] == 3
  end

  test "CV-027 should not collect coverage without the option", %{browser: browser, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    Tracing.start!(tracing(context))
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, coverage_script("a.js", 1))

    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    assert parse_trace_coverage(trace_file, browser) == nil
  end

  test "CV-028 should count only the hits after start", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      "coverage => window.__coverage__ = JSON.parse(coverage)",
      JSON.encode!(file_coverage("a.js", 3))
    )

    start_coverage(context)
    Page.evaluate!(page, "() => window.__coverage__['a.js'].s['0'] += 2")
    trace_file = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_file)
    BrowserContext.close!(context)

    data = parse_trace_coverage(trace_file, browser)
    assert data["a.js"]["s"]["0"] == 2
    assert Map.keys(data["a.js"]["statementMap"]) == ["0"]
  end

  test "CV-029 should stop collecting when tracing stops", %{browser: browser, server: server} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      "coverage => window.__coverage__ = JSON.parse(coverage)",
      JSON.encode!(file_coverage("a.js", 1))
    )

    Tracing.stop!(tracing(context))

    assert Page.evaluate!(page, "() => typeof window.__pwCoverageTake") == "undefined"
    # Leaving the document no longer stashes the counters.
    Page.evaluate!(page, "() => window.__coverage__['a.js'].s['0'] = 5")
    Page.goto!(page, server.prefix <> "/title.html")

    assert Page.evaluate!(page, "() => Object.keys(localStorage).filter(key => key.startsWith('__pwCoverage.'))") ==
             []

    assert Page.evaluate!(page, "() => typeof window.__pwCoverageTake") == "undefined"
    BrowserContext.close!(context)
  end

  test "CV-030 should surface a failure to stash the coverage", %{browser: browser, server: server, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    start_coverage(context)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Page.evaluate!(
      page,
      """
      coverage => {
        window.__coverage__ = JSON.parse(coverage);
        // The stash does not fit, the error record still does.
        const setItem = Storage.prototype.setItem;
        Storage.prototype.setItem = function(key, value) {
          if (value.length > 100)
            throw new DOMException('The quota has been exceeded.', 'QuotaExceededError');
          setItem.call(this, key, value);
        };
        window.dispatchEvent(new Event('pagehide'));
      }
      """,
      JSON.encode!(file_coverage("a.js", 3))
    )

    assert {:error, error} = Tracing.stop(tracing(context), path: Path.join(tmp_dir, "trace.zip"))
    assert Exception.message(error) =~ "Failed to stash the coverage: QuotaExceededError: The quota has been exceeded."
    BrowserContext.close!(context)
  end
end
