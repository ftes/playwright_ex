defmodule PlaywrightEx.Library.Chromium.JsCoverageTest do
  @upstream "tests/library/chromium/js-coverage.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Coverage
  alias PlaywrightEx.Page

  @moduletag :page
  @moduletag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "Chromium only")

  # it.skip(({ trace }) => trace === 'on');

  test "should work", %{page: page, server: server} do
    Coverage.start_js_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/jscoverage/simple.html", wait_until: :load)
    coverage = Coverage.stop_js_coverage!(Page.coverage(page))
    assert length(coverage) == 1
    assert hd(coverage).url =~ "/jscoverage/simple.html"
    assert hd(Enum.find(hd(coverage).functions, &(&1.functionName == "foo")).ranges).count == 1
  end

  test "should report sourceURLs", %{page: page, server: server} do
    Coverage.start_js_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/jscoverage/sourceurl.html")
    coverage = Coverage.stop_js_coverage!(Page.coverage(page))
    assert length(coverage) == 1
    assert hd(coverage).url == "nicename.js"
  end

  test "should ignore eval() scripts by default", %{page: page, server: server} do
    Coverage.start_js_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/jscoverage/eval.html")
    coverage = Coverage.stop_js_coverage!(Page.coverage(page))
    assert length(coverage) == 1
  end

  test "shouldn't ignore eval() scripts if reportAnonymousScripts is true", %{page: page, server: server} do
    # it.skip(!!process.env.PW_CLOCK);
    Coverage.start_js_coverage!(Page.coverage(page), report_anonymous_scripts: true)
    Page.goto!(page, server.prefix <> "/jscoverage/eval.html")
    coverage = Coverage.stop_js_coverage!(Page.coverage(page))
    assert Enum.any?(coverage, &match?(%{url: "", source: ~s[console.log("foo")]}, &1))
  end

  test "should report multiple scripts", %{page: page, server: server} do
    Coverage.start_js_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/jscoverage/multiple.html")
    coverage = Coverage.stop_js_coverage!(Page.coverage(page))
    assert length(coverage) == 2
    coverage = Enum.sort_by(coverage, & &1.url)
    assert Enum.at(coverage, 0).url =~ "/jscoverage/script1.js"
    assert Enum.at(coverage, 1).url =~ "/jscoverage/script2.js"
  end

  test "should NOT report scripts across navigations when enabled", %{page: page, server: server} do
    # Enabled by default.
    Coverage.start_js_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/jscoverage/multiple.html")
    Page.goto!(page, server.empty_page)
    coverage = Coverage.stop_js_coverage!(Page.coverage(page))
    assert coverage == []
  end

  test "should not hang when there is a debugger statement", %{page: page, server: server} do
    Coverage.start_js_coverage!(Page.coverage(page))
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      debugger; // eslint-disable-line no-debugger
    }
    """)

    Coverage.stop_js_coverage!(Page.coverage(page))
  end
end
