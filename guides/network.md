# Network

Playwright sees every request a page makes: you can mock it, wait for it, or send your own.
Snippets alias `PlaywrightEx.{Page, Route, ...}`.

## Mocking with routes

A route intercepts the requests whose URL matches, and its handler decides what happens to each:

```elixir
Page.route!(page, "**/api/users", &Route.fulfill(&1, json: [%{name: "Ada"}]))
Page.route!(page, "**/*.{png,jpg}", &Route.abort/1)
```

A handler of two arguments also gets the `Request`. It must `fulfill`, `continue`, `abort` or
`fallback` the route; a request whose handler does none of these hangs:

```elixir
Page.route!(page, "**/api/**", fn route, request ->
  case Request.method(request) do
    "DELETE" -> Route.fulfill(route, status: 403, json: %{error: "forbidden"})
    _ -> Route.continue(route, headers: Map.put(Request.headers(request), "x-test", "1"))
  end
end)
```

To change a real response, fetch it and fulfill with the result:

```elixir
Page.route!(page, "**/api/users", fn route ->
  response = Route.fetch!(route)
  users = APIResponse.json!(response)
  Route.fulfill(route, response: response, json: users ++ [%{name: "Grace"}])
end)
```

- The pattern is a glob, a `Regex` or a function of the URL; with `base_url`, a path such as
  `"/api/users"` is resolved against it.
- When several routes match, the one added last runs;
  [`Route.fallback/2`](`PlaywrightEx.Route.fallback/2`) hands the request to the one before.
- [`BrowserContext.route/4`](`PlaywrightEx.BrowserContext.route/4`) covers every page of the
  context, including a popup's first request.
- `times: 1` routes once; [`Page.unroute/3`](`PlaywrightEx.Page.unroute/3`) removes a route.

Like listeners, handlers run in their own processes; see the [Concurrency](concurrency.md) guide.

## Replaying a HAR

A HAR file records requests and responses. Record one against the real backend with
`update: true` (the file is written when the context closes), then replay it in tests:

```elixir
BrowserContext.route_from_har!(context, "test/fixtures/api.har", url: "**/api/**", update: true)
# ... use the app, then
BrowserContext.close!(context)
```

```elixir
BrowserContext.route_from_har!(context, "test/fixtures/api.har", url: "**/api/**")
```

Requests not in the HAR are aborted; `not_found: :fallback` sends them on to other routes or the
network. [`Page.route_from_har/3`](`PlaywrightEx.Page.route_from_har/3`) does the same for one page.

## Waiting for requests and responses

Start the wait before the action that sends the request, as for any event:

```elixir
response =
  Page.expect_response!(page, "**/api/users", fn ->
    Page.get_by_role(page, :button, name: "Reload") |> Locator.click!()
  end)

assert Response.status(response) == 200
assert [%{"name" => _} | _] = Response.json!(response)
```

`expect_request!/4` waits for the request instead, and both take a predicate in place of the URL:
`&(Response.url(&1) =~ "/api/" and Response.status(&1) >= 400)`. To watch all traffic, listen to
`:request`, `:response`, `:request_finished` or `:request_failed` with
[`Page.on/3`](`PlaywrightEx.Page.on/3`).

## API testing

`PlaywrightEx.APIRequestContext` sends HTTP requests without a browser, to test an API or to set
up data before a UI test:

```elixir
request =
  PlaywrightEx.playwright()
  |> Playwright.request()
  |> APIRequest.new_context!(
    base_url: "http://localhost:4000",
    extra_http_headers: %{"authorization" => "Bearer #{token}"}
  )

response = APIRequestContext.post!(request, "/api/issues", data: %{title: "Broken link"})
Expect.to_be_ok!(response)
assert %{"title" => "Broken link"} = APIResponse.json!(response)

APIRequestContext.dispose!(request)
```

`data:` sends a map as JSON; `form:` and `multipart:` send forms, `params:` the query string.
Responses are kept until `dispose!/1`, so in ExUnit create the context in `setup` and dispose of
it in `on_exit/1`.

[`BrowserContext.request/1`](`PlaywrightEx.BrowserContext.request/1`) (or
[`Page.request/1`](`PlaywrightEx.Page.request/1`)) is the context's own API client: it shares
cookies with the pages, so a request made there is logged in as the page is, and cookies it gets
back show up in the pages.

More: [network](https://playwright.dev/python/docs/network),
[mock APIs](https://playwright.dev/python/docs/mock),
[API testing](https://playwright.dev/python/docs/api-testing).
