# Spike 3: page + context route handlers, fallback chain, times, unroute(All) with behavior wait,
# fulfill/continue/abort, string globs resolved by LocalUtils.globToRegex (cached per handler).
defmodule PlaywrightJS.RoutingTest do
  use ExUnit.Case, async: false
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Runtime.{Heap, Promise}
  alias PlaywrightJS.Client.{BrowserContext, Locator, Page}
  alias PlaywrightJS.Client.Network.{Request, Route}

  defp body(page), do: page |> Page.locator("body") |> Locator.text_content()

  test "fulfill, glob matching, page -> context fallback chain, times" do
    %{page: page, context: context} = env = TestHelper.launch()
    test = self()

    BrowserContext.route(context, "**/*", fn route, request ->
      send(test, {:context, Request.url(request)})
      Route.fulfill(route, %{body: "from context", contentType: "text/html"})
    end)

    Page.route(page, "**/fallback.html", fn route, _request ->
      send(test, :page_fallback)
      Route.fallback(route)
    end)

    Page.route(page, ~r/page\.html$/, fn route, _ -> Route.fulfill(route, %{body: "from page", contentType: "text/html"}) end)
    Page.route(page, "http://pw.test/once.html", fn route, _ -> Route.fulfill(route, %{body: "once", contentType: "text/html"}) end, %{times: 1})
    Page.route(page, "**/json", fn route, _ -> Route.fulfill(route, %{json: %{a: 1}}) end)

    Page.goto(page, "http://pw.test/page.html")
    assert body(page) == "from page"

    Page.goto(page, "http://pw.test/fallback.html")
    assert_received :page_fallback
    assert_received {:context, "http://pw.test/fallback.html"}
    assert body(page) == "from context"

    Page.goto(page, "http://pw.test/once.html")
    assert body(page) == "once"
    Page.goto(page, "http://pw.test/once.html")
    assert body(page) == "from context"

    assert Page.evaluate(page, "fetch('/json').then(r => r.json())") == %{"a" => 1}

    # The glob was resolved once by the driver and cached on the handler.
    [json_handler | _] = Heap.get(page, :_routes)
    assert Regex.source(Heap.get(json_handler, :_urlRegex)) =~ "json"

    Page.unroute(page, ~r/page\.html$/)
    Page.goto(page, "http://pw.test/page.html")
    assert body(page) == "from context"
    TestHelper.close(env)
  end

  test "continue with overrides and abort" do
    %{page: page} = env = TestHelper.launch()
    base = TestHelper.http_server(%{"/real.html" => {"text/html", "<p>real</p>"}, "/other.html" => {"text/html", "<p>other</p>"}})

    Page.route(page, "**/real.html", fn route, _ -> Route.continue(route) end)
    Page.goto(page, base <> "/real.html")
    assert body(page) == "real"

    Page.route(page, "**/redirect-me.html", fn route, _ -> Route.continue(route, %{url: base <> "/other.html"}) end)
    Page.goto(page, base <> "/redirect-me.html")
    assert body(page) == "other"

    Page.route(page, "**/blocked.html", fn route, _ -> Route.abort(route) end)
    error = assert_raise PlaywrightJS.Client.Errors.PlaywrightError, fn -> Page.goto(page, base <> "/blocked.html") end
    assert error.message =~ "page.goto: net::ERR_FAILED"
    TestHelper.close(env)
  end

  test "unrouteAll with behavior wait waits for the running handler" do
    %{page: page, context: context} = env = TestHelper.launch()
    helper = BrowserContext.new_page(context)
    test = self()
    log = :ets.new(:log, [:public, :ordered_set])

    Page.route(page, "**/slow.html", fn route, _ ->
      send(test, :in_handler)
      # Awaiting releases the baton: dispatch and the test process keep going meanwhile.
      Page.evaluate(helper, "new Promise(r => setTimeout(r, 300))")
      :ets.insert(log, {System.monotonic_time(), :handler_done})
      Route.fulfill(route, %{body: "slow", contentType: "text/html"})
    end)

    navigation = Promise.async(fn -> Page.goto(page, "http://pw.test/slow.html") end)
    assert_receive :in_handler, 5000
    Page.unroute_all(page, %{behavior: "wait"})
    :ets.insert(log, {System.monotonic_time(), :unroute_returned})
    assert [:handler_done, :unroute_returned] == :ets.tab2list(log) |> Enum.map(&elem(&1, 1))
    Promise.await(navigation)
    assert body(page) == "slow"
    TestHelper.close(env)
  end

  test "unrouteAll with ignoreErrors swallows errors from in-flight handlers" do
    %{page: page} = env = TestHelper.launch()
    base = TestHelper.http_server(%{"/x.html" => {"text/html", "<p>real</p>"}})
    test = self()

    Page.route(page, "**/x.html", fn route, _ ->
      send(test, :in_handler)
      Page.evaluate(page, "new Promise(r => setTimeout(r, 100))")
      Route.fulfill(route, %{body: "x", contentType: "text/html"})
      send(test, :fulfilled)
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        navigation = Promise.async(fn -> Page.goto(page, base <> "/x.html") end)
        assert_receive :in_handler, 5000
        Page.unroute_all(page, %{behavior: "ignoreErrors"})
        Promise.await(navigation)
        Process.sleep(200)
      end)

    # Either the handler won, or interception was switched off first and its error was swallowed.
    assert body(page) in ["x", "real"]
    refute log =~ "Uncaught"
    TestHelper.close(env)
  end
end
