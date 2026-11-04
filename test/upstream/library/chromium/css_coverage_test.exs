defmodule PlaywrightEx.Library.Chromium.CssCoverageTest do
  @upstream "tests/library/chromium/css-coverage.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Coverage
  alias PlaywrightEx.Page

  @moduletag :page
  @moduletag skip: if(System.get_env("BROWSER", "chromium") != "chromium", do: "Chromium only")

  test "should work", %{page: page, server: server} do
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/csscoverage/simple.html")
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert length(coverage) == 1
    assert hd(coverage).url =~ "/csscoverage/simple.html"
    assert hd(coverage).ranges == [%{start: 1, end: 22}]
    range = hd(hd(coverage).ranges)
    assert binary_part(hd(coverage).text, range.start, range.end - range.start) == "div { color: green; }"
  end

  test "should report sourceURLs", %{page: page, server: server} do
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/csscoverage/sourceurl.html")
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert length(coverage) == 1
    assert hd(coverage).url == "nicename.css"
  end

  test "should report multiple stylesheets", %{page: page, server: server} do
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/csscoverage/multiple.html")
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert length(coverage) == 2
    coverage = Enum.sort_by(coverage, & &1.url)
    assert Enum.at(coverage, 0).url =~ "/csscoverage/stylesheet1.css"
    assert Enum.at(coverage, 1).url =~ "/csscoverage/stylesheet2.css"
  end

  test "should report stylesheets that have no coverage", %{page: page, server: server} do
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/csscoverage/unused.html")
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert length(coverage) == 1
    assert hd(coverage).url == "unused.css"
    assert hd(coverage).ranges == []
  end

  test "should work with media queries", %{page: page, server: server} do
    # it.skip(chromiumVersionLessThan(browserVersion, '115.0.5762.0'), ...);  -- the pinned Chromium is newer
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/csscoverage/media.html")
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert length(coverage) == 1
    assert hd(coverage).url =~ "/csscoverage/media.html"
    assert hd(coverage).ranges == [%{start: 8, end: 15}, %{start: 17, end: 38}]
  end

  test "should work with complicated usecases", %{page: page, server: server} do
    # it.skip(chromiumVersionLessThan(browserVersion, '115.0.5762.0'), ...);  -- the pinned Chromium is newer
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/csscoverage/involved.html")
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    coverage = List.update_at(coverage, 0, &Map.drop(&1, [:text, :url]))

    assert coverage == [
             %{
               ranges: [
                 %{start: 149, end: 297},
                 %{start: 306, end: 323},
                 %{start: 327, end: 433}
               ]
             }
           ]
  end

  test "should ignore injected stylesheets", %{page: page} do
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.add_style_tag!(page, content: "body { margin: 10px;}")
    # trigger style recalc
    margin = Page.evaluate!(page, "() => window.getComputedStyle(document.body).margin")
    assert margin == "10px"
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert coverage == []
  end

  test "should report stylesheets across navigations", %{page: page, server: server} do
    Coverage.start_css_coverage!(Page.coverage(page), reset_on_navigation: false)
    Page.goto!(page, server.prefix <> "/csscoverage/multiple.html")
    Page.goto!(page, server.empty_page)
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert length(coverage) == 2
  end

  test "should NOT report scripts across navigations", %{page: page, server: server} do
    # Enabled by default.
    Coverage.start_css_coverage!(Page.coverage(page))
    Page.goto!(page, server.prefix <> "/csscoverage/multiple.html")
    Page.goto!(page, server.empty_page)
    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert coverage == []
  end

  test "should work with a recently loaded stylesheet", %{page: page, server: server} do
    Coverage.start_css_coverage!(Page.coverage(page))

    Page.evaluate!(
      page,
      """
      async url => {
        document.body.textContent = 'hello, world';

        const link = document.createElement('link');
        link.rel = 'stylesheet';
        link.href = url;
        document.head.appendChild(link);
        await new Promise(x => link.onload = x);
        await new Promise(f => window.builtins.requestAnimationFrame(f));
      }
      """,
      server.prefix <> "/csscoverage/stylesheet1.css"
    )

    coverage = Coverage.stop_css_coverage!(Page.coverage(page))
    assert length(coverage) == 1
  end
end
