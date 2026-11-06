defmodule PlaywrightEx.Examples.RouteTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.APIResponse

  example "Route.continue",
    js: ~S"""
    await page.route('**/*', async (route, request) => {
      // Override headers
      const headers = {
        ...request.headers(),
        foo: 'foo-value', // set "foo" header
        bar: undefined, // remove "bar" header
      };
      await route.continue({ headers });
    });
    """ do
    Page.route!(page, "**/*", fn route, request ->
      # Override headers
      headers =
        Request.headers(request)
        # set "foo" header
        |> Map.put("foo", "foo-value")
        # remove "bar" header
        |> Map.delete("bar")

      Route.continue!(route, headers: headers)
    end)
  end

  example "Route.fallback",
    js: ~S"""
    await page.route('**/*', async route => {
      // Runs last.
      await route.abort();
    });
    await page.route('**/*', async route => {
      // Runs second.
      await route.fallback();
    });
    await page.route('**/*', async route => {
      // Runs first.
      await route.fallback();
    });
    """ do
    Page.route!(page, "**/*", fn route ->
      # Runs last.
      Route.abort!(route)
    end)

    Page.route!(page, "**/*", fn route ->
      # Runs second.
      Route.fallback!(route)
    end)

    Page.route!(page, "**/*", fn route ->
      # Runs first.
      Route.fallback!(route)
    end)
  end

  example "Route.fallback",
    js: ~S"""
    // Handle GET requests.
    await page.route('**/*', async route => {
      if (route.request().method() !== 'GET') {
        await route.fallback();
        return;
      }
      // Handling GET only.
      // ...
    });

    // Handle POST requests.
    await page.route('**/*', async route => {
      if (route.request().method() !== 'POST') {
        await route.fallback();
        return;
      }
      // Handling POST only.
      // ...
    });
    """ do
    # Handle GET requests.
    Page.route!(page, "**/*", fn route ->
      if Request.method(Route.request(route)) != "GET" do
        Route.fallback!(route)
      else
        # Handling GET only.
        # ...
      end
    end)

    # Handle POST requests.
    Page.route!(page, "**/*", fn route ->
      if Request.method(Route.request(route)) != "POST" do
        Route.fallback!(route)
      else
        # Handling POST only.
        # ...
      end
    end)
  end

  example "Route.fallback",
    js: ~S"""
    await page.route('**/*', async (route, request) => {
      // Override headers
      const headers = {
        ...request.headers(),
        foo: 'foo-value', // set "foo" header
        bar: undefined, // remove "bar" header
      };
      await route.fallback({ headers });
    });
    """ do
    Page.route!(page, "**/*", fn route, request ->
      # Override headers
      headers =
        Request.headers(request)
        # set "foo" header
        |> Map.put("foo", "foo-value")
        # remove "bar" header
        |> Map.delete("bar")

      Route.fallback!(route, headers: headers)
    end)
  end

  example "Route.fetch",
    js: ~S"""
    await page.route('https://dog.ceo/api/breeds/list/all', async route => {
      const response = await route.fetch();
      const json = await response.json();
      json.message['big_red_dog'] = [];
      await route.fulfill({ response, json });
    });
    """ do
    Page.route!(page, "https://dog.ceo/api/breeds/list/all", fn route ->
      response = Route.fetch!(route)
      json = APIResponse.json!(response)
      json = put_in(json["message"]["big_red_dog"], [])
      Route.fulfill!(route, response: response, json: json)
    end)
  end

  example "Route.fulfill",
    js: ~S"""
    await page.route('**/*', async route => {
      await route.fulfill({
        status: 404,
        contentType: 'text/plain',
        body: 'Not Found!'
      });
    });
    """ do
    Page.route!(page, "**/*", fn route ->
      Route.fulfill!(route, status: 404, content_type: "text/plain", body: "Not Found!")
    end)
  end

  example "Route.fulfill",
    js: ~S"""
    await page.route('**/xhr_endpoint', route => route.fulfill({ path: 'mock_data.json' }));
    """ do
    Page.route!(page, "**/xhr_endpoint", &Route.fulfill!(&1, path: "mock_data.json"))
  end
end
