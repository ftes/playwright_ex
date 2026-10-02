defmodule PlaywrightEx.RouteTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.Supervisor.Connection

  test "replaces a Formstack-style script while navigation blocks", %{page: page, frame: frame} do
    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/forms/js.php/**",
               fn route, request ->
                 assert request.method == "GET"

                 Route.fulfill(route,
                   content_type: "application/javascript",
                   body: "window.Formstack = {submit: () => 'acknowledged'}"
                 )
               end,
               timeout: @timeout
             )

    assert {:ok, _} =
             Page.route(
               page.guid,
               "https://app.test/",
               fn route, _ ->
                 Route.fulfill(route,
                   content_type: "text/html",
                   body:
                     "<script src='https://external.invalid/forms/js.php/123'></script><script>document.title = Formstack.submit()</script>"
                 )
               end,
               timeout: @timeout
             )

    assert {:ok, _} = Frame.goto(frame.guid, url: "https://app.test/", timeout: @timeout)
    assert {:ok, "acknowledged"} = eval(frame.guid, "() => document.title")
  end

  test "newest page handlers precede context handlers and fallback keeps original matching", %{
    browser_context: context,
    page: page,
    frame: frame
  } do
    owner = self()

    assert {:ok, _} =
             BrowserContext.route(
               context.guid,
               ~r/original/,
               fn route, request ->
                 send(owner, {:context, request.url, request.method})
                 Route.fulfill(route, body: "context")
               end,
               timeout: @timeout
             )

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/original",
               fn route, request ->
                 send(owner, {:older, request.url})
                 Route.fallback(route)
               end,
               timeout: @timeout
             )

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/original",
               fn route, _ ->
                 send(owner, :newest)
                 Route.fallback(route, url: "https://routing.invalid/changed", method: "POST")
               end,
               timeout: @timeout
             )

    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/original", timeout: @timeout)
    assert_receive :newest
    assert_receive {:older, "https://routing.invalid/changed"}
    assert_receive {:context, "https://routing.invalid/changed", "POST"}
  end

  test "continue bypasses remaining handlers, whereas unmatched requests reach the network", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/matched",
               fn route, _ ->
                 send(owner, :unexpected)
                 Route.fulfill(route, body: "wrong")
               end,
               timeout: @timeout
             )

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/matched",
               fn route, _ ->
                 send(owner, :continued)
                 Route.continue(route)
               end,
               timeout: @timeout
             )

    assert {:error, _} = Frame.goto(frame.guid, url: "http://127.0.0.1:54321/matched", timeout: @timeout)
    assert {:error, _} = Frame.goto(frame.guid, url: "http://127.0.0.1:54321/unmatched", timeout: @timeout)
    assert_receive :continued
    refute_receive :unexpected
  end

  test "times is consumed atomically and unroute selects callback identity", %{page: page, frame: frame} do
    base = fn route, _ -> Route.fulfill(route, body: "base") end
    once = fn route, _ -> Route.fulfill(route, body: "once") end
    assert {:ok, _} = Page.route(page.guid, "**/*", base, timeout: @timeout)
    assert {:ok, _} = Page.route(page.guid, "**/*", once, times: 1, timeout: @timeout)

    for expected <- ["once", "base"] do
      assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)
      assert {:ok, ^expected} = eval(frame.guid, "() => document.body.textContent")
    end

    assert {:ok, _} = Page.unroute(page.guid, "**/*", once, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)
    assert {:ok, _} = Page.unroute(page.guid, "**/*", base, timeout: @timeout)
    assert {:error, _} = Frame.goto(frame.guid, url: "http://127.0.0.1:54321/", timeout: @timeout)
  end

  test "callback errors abort requests and are reported without breaking the connection", %{page: page, frame: frame} do
    assert {:ok, _} = Page.route(page.guid, "**/*", fn _, _ -> raise "broken callback" end, timeout: @timeout)
    assert {:error, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)

    assert_receive {:playwright_route_error,
                    %{reason: {:callback_failed, :error, %RuntimeError{message: "broken callback"}, [_ | _]}}}

    assert {:ok, _} = Page.unroute_all(page.guid, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
  end

  test "wait removal includes exhausted callbacks and waits for completion", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn route, _ ->
                 send(owner, {:running, self()})

                 receive do
                   :finish -> Route.fulfill(route, body: "done")
                 end
               end,
               times: 1,
               timeout: @timeout
             )

    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:running, worker}, @timeout
    removal = Task.async(fn -> Page.unroute_all(page.guid, behavior: :wait, timeout: @timeout) end)
    assert Task.yield(removal, 20) == nil
    send(worker, :finish)
    assert {:ok, _} = Task.await(removal)
    assert {:ok, _} = Task.await(navigation)
  end

  test "ignore_errors removal lets callbacks run but suppresses their failures", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn _, _ ->
                 send(owner, {:running, self()})

                 receive do
                   :finish -> raise "ignored"
                 end
               end,
               timeout: @timeout
             )

    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:running, worker}, @timeout
    assert {:ok, _} = Page.unroute_all(page.guid, behavior: :ignore_errors, timeout: @timeout)
    send(worker, :finish)
    assert {:error, _} = Task.await(navigation)
    refute_receive {:playwright_route_error, _}
  end

  test "closing a page stops callbacks and releases handlers", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn _, _ ->
                 send(owner, {:running, self()})

                 receive do
                   :never -> :ok
                 end
               end,
               timeout: @timeout
             )

    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:running, worker}, @timeout
    ref = Process.monitor(worker)
    assert {:ok, _} = Page.close(page.guid, timeout: @timeout)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert {:error, _} = Task.await(navigation)
    refute_receive {:playwright_route_error, _}
  end

  test "binary fulfillment sets response headers and rejects protocol-only options", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn route, _ ->
                 assert_raise NimbleOptions.ValidationError, fn -> Route.fulfill(route, is_base64: true) end

                 send(
                   owner,
                   Route.fulfill(route,
                     status: 201,
                     headers: %{"X-Test" => "yes"},
                     content_type: "text/plain; charset=utf-8",
                     body: "héllo"
                   )
                 )

                 send(owner, Route.abort(route))
               end,
               timeout: @timeout
             )

    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)
    assert_receive {:ok, _}
    assert_receive {:error, %{reason: :route_already_handled}}
    assert {:ok, "héllo"} = eval(frame.guid, "() => document.body.textContent")
  end

  test "fallback waits for the current callback to finish and doesn't repeat context handlers", %{
    browser_context: context,
    page: page,
    frame: frame
  } do
    owner = self()

    assert {:ok, _} =
             BrowserContext.route(
               context.guid,
               "**/*",
               fn route, _ ->
                 send(owner, :context)
                 Route.fallback(route)
               end,
               timeout: @timeout
             )

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn route, _ ->
                 Route.fallback(route)
                 send(owner, {:falling_back, self()})

                 receive do
                   :finish -> :ok
                 end
               end,
               timeout: @timeout
             )

    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "http://127.0.0.1:54321/", timeout: @timeout) end)
    assert_receive {:falling_back, worker}, @timeout
    refute_receive :context
    send(worker, :finish)
    assert {:error, _} = Task.await(navigation)
    assert_receive :context
    refute_receive :context
  end

  test "context routing covers popup initial navigation", %{browser_context: context, frame: frame} do
    owner = self()

    assert {:ok, _} =
             BrowserContext.route(
               context.guid,
               "**/popup",
               fn route, request ->
                 send(owner, {:popup_request, request.url})
                 Route.fulfill(route, content_type: "text/html", body: "<title>intercepted popup</title>")
               end,
               timeout: @timeout
             )

    {:ok, pending} = PlaywrightEx.EventWaiter.arm(context.guid, :page, timeout: @timeout)
    assert {:ok, _} = eval(frame.guid, "() => { window.open('https://routing.invalid/popup'); }")
    assert_receive {:popup_request, "https://routing.invalid/popup"}, @timeout
    assert {:ok, %{params: %{page: popup}}} = PlaywrightEx.EventWaiter.await(pending)
    popup = PlaywrightEx.Connection.initializer!(Connection, popup.guid)
    assert {:ok, _} = Frame.wait_for_load_state(popup.main_frame.guid, state: "load", timeout: @timeout)
    assert {:ok, "intercepted popup"} = eval(popup.main_frame.guid, "() => document.title")
  end

  test "concurrent requests consume times exactly once", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(page.guid, "**/*", fn route, _ -> Route.fulfill(route, body: "base") end, timeout: @timeout)

    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/fetch*",
               fn route, _ ->
                 send(owner, :once)
                 Route.fulfill(route, body: "once")
               end,
               times: 1,
               timeout: @timeout
             )

    assert {:ok, bodies} =
             eval(frame.guid, "() => Promise.all([1,2,3,4].map(n => fetch('/fetch' + n).then(r => r.text())))")

    assert Enum.count(bodies, &(&1 == "once")) == 1
    assert Enum.count(bodies, &(&1 == "base")) == 3
    assert_receive :once
    refute_receive :once
  end

  test "default removal preserves running callbacks and reports failures", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn _, _ ->
                 send(owner, {:running, self()})

                 receive do
                   :finish -> exit(:callback_exit)
                 end
               end,
               timeout: @timeout
             )

    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:running, worker}, @timeout
    assert {:ok, _} = Page.unroute_all(page.guid, timeout: @timeout)
    assert Process.alive?(worker)
    send(worker, :finish)
    assert {:error, _} = Task.await(navigation)
    assert_receive {:playwright_route_error, %{reason: {:callback_failed, :exit, :callback_exit, _}}}
  end

  test "a returned unresolved handle stays paused and can be resolved by another process", %{page: page, frame: frame} do
    owner = self()
    assert {:ok, _} = Page.route(page.guid, "**/*", fn route, _ -> send(owner, {:handle, route}) end, timeout: @timeout)
    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:handle, route}, @timeout
    assert {:ok, _} = Page.unroute(page.guid, "**/*", timeout: @timeout)
    assert Task.yield(navigation, 20) == nil
    assert {:ok, _} = Route.fulfill(route, body: "resolved later")
    assert {:ok, _} = Task.await(navigation)
  end

  test "closing a page cancels its context callbacks but preserves context registration", %{
    browser_context: context,
    page: page,
    frame: frame
  } do
    owner = self()

    assert {:ok, _} =
             BrowserContext.route(
               context.guid,
               "**/*",
               fn _, _ ->
                 send(owner, {:running, self()})

                 receive do
                   :never -> :ok
                 end
               end,
               timeout: @timeout
             )

    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:running, worker}, @timeout
    ref = Process.monitor(worker)
    assert {:ok, _} = Page.close(page.guid, timeout: @timeout)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert {:error, _} = Task.await(navigation)
    {:ok, next} = BrowserContext.new_page(context.guid, timeout: @timeout)

    navigation =
      Task.async(fn -> Frame.goto(next.main_frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)

    assert_receive {:running, next_worker}, @timeout
    ref = Process.monitor(next_worker)
    assert {:ok, _} = BrowserContext.close(context.guid, timeout: @timeout)
    assert_receive {:DOWN, ^ref, :process, ^next_worker, :killed}
    assert {:error, _} = Task.await(navigation)
    refute_receive {:playwright_route_error, _}
  end

  test "fulfillment preserves arbitrary bytes, status and headers", %{page: page, frame: frame} do
    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn route, _ -> Route.fulfill(route, content_type: "text/html", body: "<p>fixture</p>") end,
               timeout: @timeout
             )

    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/bytes",
               fn route, _ ->
                 assert {:error, %{reason: :timeout}} = Route.fallback(route, timeout: 0)

                 Route.fulfill(route,
                   status: 201,
                   headers: %{"X-Test" => "yes"},
                   content_type: "application/octet-stream",
                   body: <<0, 255, 128>>
                 )
               end,
               timeout: @timeout
             )

    assert {:ok, [201, "yes", "3", [0, 255, 128]]} =
             eval(
               frame.guid,
               "async () => { const r = await fetch('/bytes'); return [r.status, r.headers.get('x-test'), r.headers.get('content-length'), Array.from(new Uint8Array(await r.arrayBuffer()))]; }"
             )
  end

  test "registration validates limits and does not install a zero-timeout handler", %{page: page} do
    callback = fn route, _ -> Route.abort(route) end

    assert_raise NimbleOptions.ValidationError, fn ->
      Page.route(page.guid, "**/*", callback, times: 0, timeout: @timeout)
    end

    assert {:error, %{reason: :timeout}} = Page.route(page.guid, "**/*", callback, timeout: 0)
    {:ok, router} = PlaywrightEx.Connection.routing(Connection)
    state = :sys.get_state(router)
    refute Enum.any?(state.handlers, &(&1.guid == page.guid))
    refute MapSet.member?(state.subscriptions, page.guid)
  end

  @tag skip:
         if(Application.compile_env(:playwright_ex, :ws_endpoint),
           do: "loopback server is local to the driver host",
           else: false
         )
  test "continue and unmatched requests reach a local server; fulfill and abort do not", %{page: page, frame: frame} do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    owner = self()
    start_supervised!({Task, fn -> serve(socket, owner) end})
    url = "http://127.0.0.1:#{port}"

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/continue",
               fn route, _ ->
                 Route.continue(route, method: "POST", post_data: "hello", headers: %{"X-Test" => "override"})
               end,
               timeout: @timeout
             )

    assert {:ok, _} =
             Page.route(page.guid, "**/fulfill", fn route, _ -> Route.fulfill(route, body: "stub") end, timeout: @timeout)

    assert {:ok, _} = Page.route(page.guid, "**/abort", fn route, _ -> Route.abort(route) end, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: url <> "/continue", timeout: @timeout)
    assert_receive {:network, :POST, "/continue", headers, "hello"}
    assert {"x-test", "override"} in headers
    assert {:ok, "network"} = eval(frame.guid, "() => document.body.textContent")
    assert {:ok, _} = Frame.goto(frame.guid, url: url <> "/unmatched", timeout: @timeout)
    assert_receive {:network, :GET, "/unmatched", _, ""}
    assert {:ok, _} = Frame.goto(frame.guid, url: url <> "/fulfill", timeout: @timeout)
    assert {:error, _} = Frame.goto(frame.guid, url: url <> "/abort", timeout: @timeout)
    refute_receive {:network, _, "/fulfill", _, _}
    refute_receive {:network, _, "/abort", _, _}
  end

  defp serve(socket, owner) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        {:ok, {:http_request, method, {:abs_path, path}, _}} = :gen_tcp.recv(client, 0, 5_000)
        headers = read_headers(client, [])
        :ok = :inet.setopts(client, packet: :raw)
        length = headers |> List.keyfind("content-length", 0, {"", "0"}) |> elem(1) |> String.to_integer()

        body =
          if length > 0 do
            {:ok, body} = :gen_tcp.recv(client, length, 5_000)
            body
          else
            ""
          end

        send(owner, {:network, method, path, headers, body})

        :ok =
          :gen_tcp.send(
            client,
            "HTTP/1.1 200 OK\r\nContent-Length: 7\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nnetwork"
          )

        :gen_tcp.close(client)
        serve(socket, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_headers(client, headers) do
    case :gen_tcp.recv(client, 0, 5_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(client, [{String.downcase(to_string(name)), value} | headers])
    end
  end
end
