defmodule PlaywrightEx.Isomorphic.UrlMatchTest do
  # Not mirrored from upstream: a function URL matcher gets a `URI`, as upstream's gets a `URL`
  # (`urlMatches`), also for a URL `URI.new/1` rejects; a URL `new URL` rejects matches nothing.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route

  @moduletag :page

  defp reporting(tag) do
    test = self()

    fn uri ->
      send(test, {tag, uri})
      true
    end
  end

  test "waitForURL, route, frame and toHaveURL give a function matcher a URI", %{page: page, server: server} do
    test = self()

    Page.route!(
      page,
      fn uri ->
        send(test, {:route, uri})
        uri.path == "/filter"
      end,
      &Route.fulfill(&1, body: "filtered")
    )

    # `URI.new/1` rejects `[`.
    Page.goto!(page, server.prefix <> "/filter?filter[name]=x")
    assert_receive {:route, %URI{scheme: "http", path: "/filter", query: "filter[name]=x"}}

    Page.wait_for_url!(page, reporting(:wait_for_url))
    assert_received {:wait_for_url, %URI{path: "/filter", query: "filter[name]=x"}}

    assert Page.frame(page, %{url: reporting(:frame)}) == Page.main_frame(page)
    assert_received {:frame, %URI{path: "/filter", query: "filter[name]=x"}}

    Expect.to_have_url!(page, reporting(:to_have_url))
    assert_received {:to_have_url, %URI{path: "/filter", query: "filter[name]=x"}}
  end

  test "a function matcher gets a URI for a data URL", %{page: page} do
    # `URI.new/1` rejects `<`.
    Page.goto!(page, "data:text/html,<div>A</div>")

    Page.wait_for_url!(page, reporting(:wait_for_url))
    assert_received {:wait_for_url, %URI{scheme: "data", path: "text/html,<div>A</div>"}}

    Expect.to_have_url!(page, reporting(:to_have_url))
    assert_received {:to_have_url, %URI{scheme: "data", path: "text/html,<div>A</div>"} = uri}
    assert URI.to_string(uri) == "data:text/html,<div>A</div>"
  end

  test "url_matches/5 gives a function matcher the URI of an absolute URL" do
    assert UrlMatch.url_matches(nil, nil, "http://a/x?filter[name]=x", reporting(:matcher))
    assert_received {:matcher, %URI{host: "a", path: "/x", query: "filter[name]=x"}}

    assert UrlMatch.url_matches(nil, nil, "data:text/html,<div>", reporting(:matcher))
    assert_received {:matcher, %URI{scheme: "data", path: "text/html,<div>"}}
  end

  test "url_matches/5 matches nothing for a relative or non-URL string, without calling the matcher" do
    for url <- ["/x?filter[name]=x", "x.html", "not a url", ""] do
      refute UrlMatch.url_matches(nil, nil, url, reporting(:matcher))
    end

    refute_received {:matcher, _}
  end
end
