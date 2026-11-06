defmodule PlaywrightEx.Examples.RequestTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  # The redirect is a fulfilled route, which WebKit doesn't follow (upstream's page-route.spec.ts).
  @redirect if(PlaywrightEx.TestBrowser.name() == "webkit", do: "WebKit can't fulfill a route with a redirect")

  example "Request.frame",
    js: ~S"""
    const frameUrl = request.frame().url();
    """,
    given: [request: Page.goto!(page, "https://example.com/") |> Response.request()] do
    frame_url = Request.frame(request) |> Frame.url()
  end

  example "Request.frame",
    js: ~S"""
    if (request.serviceWorker())
      console.log(`request ${request.url()} from a service worker`);
    else if (request.isNavigationRequest())
      console.log(`request ${request.url()} is a navigation request`);
    else
      console.log(`request ${request.url()} from a frame ${request.frame().url()}`);
    """,
    given: [request: Page.goto!(page, "https://example.com/") |> Response.request()] do
    cond do
      Request.service_worker(request) ->
        IO.puts("request #{Request.url(request)} from a service worker")

      Request.is_navigation_request(request) ->
        IO.puts("request #{Request.url(request)} is a navigation request")

      true ->
        IO.puts("request #{Request.url(request)} from a frame #{Request.frame(request) |> Frame.url()}")
    end
  end

  example "Request.redirectedFrom",
    js: ~S"""
    const response = await page.goto('http://example.com');
    console.log(response.request().redirectedFrom().url()); // 'http://example.com'
    """,
    given: [_: redirect_to_https(page)],
    skip: @redirect do
    response = Page.goto!(page, "http://example.com")
    Response.request(response) |> Request.redirected_from() |> Request.url()
    # => "http://example.com/"
  end

  example "Request.redirectedFrom",
    js: ~S"""
    const response = await page.goto('https://google.com');
    console.log(response.request().redirectedFrom()); // null
    """ do
    response = Page.goto!(page, "https://google.com")
    Response.request(response) |> Request.redirected_from()
    # => nil
  end

  example "Request.redirectedTo",
    js: ~S"""
    console.log(request.redirectedFrom().redirectedTo() === request); // true
    """,
    given: [
      _: redirect_to_https(page),
      request: Page.goto!(page, "http://example.com") |> Response.request()
    ],
    skip: @redirect do
    # prints true
    IO.puts(Request.redirected_to(Request.redirected_from(request)) == request)
  end

  example "Request.timing",
    js: ~S"""
    const requestFinishedPromise = page.waitForEvent('requestfinished');
    await page.goto('http://example.com');
    const request = await requestFinishedPromise;
    console.log(request.timing());
    """ do
    request_finished_promise = Page.wait_for_event(page, :request_finished)
    Page.goto!(page, "http://example.com")
    request = PlaywrightEx.Promise.await!(request_finished_promise)
    Request.timing(request)
    # => %{startTime: 1730000000000.0, domainLookupStart: -1, ...}
  end

  # http://example.com/ redirects to https://example.com/.
  defp redirect_to_https(page) do
    Page.route!(page, "http://example.com/", fn route ->
      Route.fulfill!(route, status: 301, headers: %{"location" => "https://example.com/"})
    end)
  end
end
