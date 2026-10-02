defmodule PlaywrightEx.RouteTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route

  test "replaces a Formstack script during synchronous navigation", %{page: page, frame: frame} do
    callback = fn route, request ->
      case URI.parse(request.url).path do
        "/forms/js.php/123" ->
          Route.fulfill(route,
            content_type: "application/javascript",
            body: "window.Formstack = {submit: () => 'acknowledged'}"
          )

        _ ->
          Route.fulfill(route,
            content_type: "text/html",
            body:
              "<script src='https://external.invalid/forms/js.php/123'></script><script>document.title = Formstack.submit()</script>"
          )
      end
    end

    assert {:ok, _} = Page.route(page.guid, "**/*", callback, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: "https://app.test/", timeout: @timeout)
    assert {:ok, "acknowledged"} = eval(frame.guid, "() => document.title")
  end

  test "page match takes precedence; unmatched requests reach the context", %{
    browser_context: context,
    page: page,
    frame: frame
  } do
    assert {:ok, _} =
             BrowserContext.route(context.guid, "**/*", fn r, _ -> Route.fulfill(r, body: "context") end,
               timeout: @timeout
             )

    assert {:ok, _} = Page.route(page.guid, "**/page", fn r, _ -> Route.fulfill(r, body: "page") end, timeout: @timeout)

    for {path, expected} <- [{"page", "page"}, {"other", "context"}] do
      assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/" <> path, timeout: @timeout)
      assert {:ok, ^expected} = eval(frame.guid, "() => document.body.textContent")
    end
  end

  test "continue bypasses context handlers", %{browser_context: context, page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             BrowserContext.route(
               context.guid,
               "**/*",
               fn r, _ ->
                 send(owner, :context)
                 Route.fulfill(r, body: "wrong")
               end,
               timeout: @timeout
             )

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn r, _ ->
                 send(owner, :continued)
                 Route.continue(r)
               end,
               timeout: @timeout
             )

    assert {:error, _} = Frame.goto(frame.guid, url: "http://127.0.0.1:54321/", timeout: @timeout)
    assert_receive :continued
    refute_receive :context
  end

  test "one handler per target; removal matches identity and allows re-registration", %{page: page, frame: frame} do
    callback = fn r, _ -> Route.fulfill(r, body: "original") end
    other = fn r, _ -> Route.abort(r) end
    assert {:ok, _} = Page.route(page.guid, "**/*", callback, timeout: @timeout)
    assert {:error, %{reason: :route_already_registered}} = Page.route(page.guid, "**/*", other, timeout: @timeout)
    assert {:ok, _} = Page.unroute(page.guid, "**/*", other, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)
    assert {:ok, "original"} = eval(frame.guid, "() => document.body.textContent")
    assert {:ok, _} = Page.unroute(page.guid, "**/*", callback, timeout: @timeout)
    assert {:ok, _} = Page.route(page.guid, "**/*", other, timeout: @timeout)
    assert {:ok, _} = Page.unroute_all(page.guid, timeout: @timeout)
  end

  @tag capture_log: true
  test "callback assertions fail the registering process through its OTP link", %{page: page, frame: frame} do
    parent = self()

    {owner, ref} =
      spawn_monitor(fn ->
        {:ok, _} = Page.route(page.guid, "**/*", fn _, _ -> assert false, "callback assertion" end, timeout: @timeout)
        send(parent, :armed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :armed, @timeout
    assert {:error, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)

    assert_receive {:DOWN, ^ref, :process, ^owner, {:playwright_route_error, :error, %ExUnit.AssertionError{}, [_ | _]}},
                   @timeout

    assert {:ok, _} = Page.route(page.guid, "**/*", fn r, _ -> Route.fulfill(r, body: "recovered") end, timeout: @timeout)
  end

  test "explicit message mode isolates failures and aborts unresolved requests", %{page: page, frame: frame} do
    assert {:ok, _} = Page.route(page.guid, "**/*", fn _, _ -> raise "broken" end, on_error: :message, timeout: @timeout)
    assert {:error, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)

    assert_receive {:playwright_route_error,
                    %{reason: {:playwright_route_error, :error, %RuntimeError{message: "broken"}, _}}},
                   @timeout

    assert {:ok, _} = Page.unroute_all(page.guid, timeout: @timeout)
  end

  test "returning unresolved is a callback failure", %{page: page, frame: frame} do
    assert {:ok, _} = Page.route(page.guid, "**/*", fn _, _ -> :ok end, on_error: :message, timeout: @timeout)
    assert {:error, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)

    assert_receive {:playwright_route_error,
                    %{reason: {:playwright_route_error, :error, %RuntimeError{message: message}, _}}},
                   @timeout

    assert message =~ "without fulfilling"
  end

  test "removal cancels running callbacks without failing their owner", %{page: page, frame: frame} do
    owner = self()

    assert {:ok, _} =
             Page.route(
               page.guid,
               "**/*",
               fn route, _ ->
                 send(owner, {:running, self(), route})

                 receive do
                   :never -> :ok
                 end
               end,
               timeout: @timeout
             )

    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:running, worker, route}, @timeout
    assert {:error, %{reason: :route_callback_only}} = Route.fulfill(route, body: "outside callback")
    ref = Process.monitor(worker)
    assert {:ok, _} = Page.unroute_all(page.guid, timeout: @timeout)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @timeout
    assert {:error, _} = Task.await(navigation)
  end

  test "context covers popup initial requests", %{browser_context: context, frame: frame} do
    owner = self()

    assert {:ok, _} =
             BrowserContext.route(
               context.guid,
               "**/popup",
               fn r, _ ->
                 send(owner, :popup)
                 Route.fulfill(r, body: "popup")
               end,
               timeout: @timeout
             )

    assert {:ok, _} = eval(frame.guid, "() => { window.open('https://routing.invalid/popup'); }")
    assert_receive :popup, @timeout
  end

  test "page closure cancels context callbacks while context registration survives", %{
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
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @timeout
    assert {:error, _} = Task.await(navigation)

    assert {:error, %{reason: :route_already_registered}} =
             BrowserContext.route(context.guid, "**/*", fn _, _ -> :ok end, timeout: @timeout)

    assert {:ok, handler} = Connection.fetch_route_handler(PlaywrightEx.Supervisor.Connection, context.guid)
    ref = Process.monitor(handler)
    assert {:ok, _} = BrowserContext.close(context.guid, timeout: @timeout)
    assert_receive {:DOWN, ^ref, :process, ^handler, :normal}, @timeout
  end

  test "owner exit tears down registration and active callbacks", %{page: page, frame: frame} do
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        {:ok, _} =
          Page.route(
            page.guid,
            "**/*",
            fn _, _ ->
              send(parent, {:running, self()})

              receive do
                :never -> :ok
              end
            end,
            timeout: @timeout
          )

        send(parent, :armed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :armed, @timeout
    navigation = Task.async(fn -> Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout) end)
    assert_receive {:running, worker}, @timeout
    ref = Process.monitor(worker)
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @timeout
    assert {:error, _} = Task.await(navigation)
  end

  test "zero timeout and unsupported options do not install handlers", %{page: page} do
    callback = fn r, _ -> Route.abort(r) end

    assert_raise NimbleOptions.ValidationError, fn ->
      Page.route(page.guid, "**/*", callback, times: 1, timeout: @timeout)
    end

    assert_raise NimbleOptions.ValidationError, fn -> Page.unroute_all(page.guid, behavior: :wait, timeout: @timeout) end
    assert {:error, %{reason: :timeout}} = Page.route(page.guid, "**/*", callback, timeout: 0)
    assert {:ok, _} = Page.route(page.guid, "**/*", callback, timeout: @timeout)
  end

  test "driver resolves globs against base URL", %{browser: browser} do
    {:ok, context} =
      PlaywrightEx.Browser.new_context(browser.guid, base_url: "https://routing.invalid", timeout: @timeout)

    {:ok, page} = BrowserContext.new_page(context.guid, timeout: @timeout)
    callback = fn route, _ -> Route.fulfill(route, body: "base URL") end
    assert {:ok, _} = Page.route(page.guid, "/relative", callback, timeout: @timeout)
    assert {:error, %{reason: :timeout}} = Page.unroute_all(page.guid, timeout: 0)
    assert {:ok, _} = Frame.goto(page.main_frame.guid, url: "/relative", timeout: @timeout)
    assert {:ok, "base URL"} = eval(page.main_frame.guid, "() => document.body.textContent")
  end

  test "connection shutdown cancels callbacks without failing their owner" do
    name = Module.concat(__MODULE__, Isolated)
    config = Keyword.put(Application.get_all_env(:playwright_ex), :name, name)
    start_supervised!({PlaywrightEx.Supervisor, config})
    connection = PlaywrightEx.Supervisor.connection_name(name)
    opts = [connection: connection, timeout: @timeout]
    {:ok, browser} = PlaywrightEx.launch_browser(:chromium, opts)
    {:ok, context} = PlaywrightEx.Browser.new_context(browser.guid, opts)
    {:ok, page} = BrowserContext.new_page(context.guid, opts)
    owner = self()

    callback = fn _, _ ->
      send(owner, {:running, self()})

      receive do
        :never -> :ok
      end
    end

    {:ok, _} = Page.route(page.guid, "**/*", callback, opts)
    {:ok, handler} = Connection.fetch_route_handler(connection, page.guid)
    handler_ref = Process.monitor(handler)

    navigation =
      Task.async(fn -> Frame.goto(page.main_frame.guid, Keyword.put(opts, :url, "https://routing.invalid/")) end)

    assert_receive {:running, worker}, @timeout
    worker_ref = Process.monitor(worker)
    :ok = stop_supervised(PlaywrightEx.Supervisor)
    assert_receive {:DOWN, ^handler_ref, :process, ^handler, :normal}, @timeout
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
    assert {:error, _} = Task.await(navigation)
  end

  test "fulfillment preserves repeated response headers", %{page: page, frame: frame, browser_context: context} do
    callback = fn route, _ ->
      {:ok, _} =
        Route.fulfill(route,
          headers: [{"Set-Cookie", "first=1; Path=/"}, {"set-cookie", "second=2; Path=/"}],
          body: "cookies"
        )
    end

    {:ok, _} = Page.route(page.guid, "**/*", callback, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)
    {:ok, cookies} = BrowserContext.cookies(context.guid, timeout: @timeout)
    assert Enum.sort(Enum.map(cookies, &{&1.name, &1.value})) == [{"first", "1"}, {"second", "2"}]
  end

  test "detaching an iframe cancels its callback without closing the page", %{page: page, frame: frame} do
    owner = self()

    callback = fn _, _ ->
      send(owner, {:running, self()})

      receive do
        :never -> :ok
      end
    end

    {:ok, _} = Page.route(page.guid, "**/pending", callback, timeout: @timeout)
    {:ok, handler} = Connection.fetch_route_handler(PlaywrightEx.Supervisor.Connection, page.guid)

    assert {:ok, _} =
             eval(
               frame.guid,
               "() => { const f = document.createElement('iframe'); f.src = 'https://routing.invalid/pending'; document.body.append(f); }"
             )

    assert_receive {:running, worker}, @timeout
    ref = Process.monitor(worker)
    assert {:ok, _} = eval(frame.guid, "() => document.querySelector('iframe').remove()")
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, @timeout
    state = :sys.get_state(handler)
    assert state.workers == %{}
    assert state.subscriptions == MapSet.new([page.guid])
  end

  @tag :tmp_dir
  test "fulfill supports JSON values and local files with inferred or explicit content type", %{
    page: page,
    frame: frame,
    tmp_dir: tmp_dir
  } do
    script = Path.join(tmp_dir, "stub.js")
    File.write!(script, "window.stubLoaded = true;")
    bytes = Path.join(tmp_dir, "fixture.unknown-extension")
    File.write!(bytes, <<0, 255>>)

    callback = fn route, request ->
      opts =
        case URI.parse(request.url).path do
          "/json" ->
            [json: %{ok: true}]

          "/null" ->
            [json: nil]

          "/false" ->
            [json: false]

          "/custom" ->
            [json: %{ok: true}, content_type: "application/custom+json"]

          "/header-json" ->
            [json: %{ok: true}, headers: %{"Content-Type" => "application/vnd.api+json"}]

          "/header-file" ->
            [path: script, headers: [{"Content-Type", "text/plain"}]]

          "/override" ->
            [json: false, headers: %{"Content-Type" => "text/plain"}, content_type: "application/custom+json"]

          "/script" ->
            [path: script]

          "/bytes" ->
            [path: bytes]

          _ ->
            [body: "<p>fixture</p>", content_type: "text/html"]
        end

      {:ok, _} = Route.fulfill(route, opts)
    end

    assert {:ok, _} = Page.route(page.guid, "**/*", callback, timeout: @timeout)

    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)

    assert {:ok, results} =
             eval(
               frame.guid,
               "async () => Promise.all(['/json','/null','/false','/custom','/header-json','/header-file','/override','/script','/bytes'].map(async path => { const r = await fetch(path); return [r.headers.get('content-type'), Array.from(new Uint8Array(await r.arrayBuffer()))]; }))"
             )

    assert results ==
             Enum.map(
               [
                 {"application/json", ~s({"ok":true})},
                 {"application/json", "null"},
                 {"application/json", "false"},
                 {"application/custom+json", ~s({"ok":true})},
                 {"application/vnd.api+json", ~s({"ok":true})},
                 {"text/plain", "window.stubLoaded = true;"},
                 {"application/custom+json", "false"},
                 {MIME.from_path(script), "window.stubLoaded = true;"},
                 {"application/octet-stream", <<0, 255>>}
               ],
               fn {type, body} -> [type, :binary.bin_to_list(body)] end
             )
  end

  test "fulfill rejects conflicting sources and file/JSON errors without consuming the handle", %{
    page: page,
    frame: frame
  } do
    callback = fn route, _ ->
      for opts <- [[body: "", json: nil], [body: "", path: "missing"], [json: false, path: "missing"]] do
        assert_raise ArgumentError, fn -> Route.fulfill(route, opts) end
      end

      assert_raise File.Error, fn -> Route.fulfill(route, path: "/nonexistent-playwright-ex/fixture.js") end
      assert_raise Protocol.UndefinedError, fn -> Route.fulfill(route, json: self()) end
      {:ok, _} = Route.fulfill(route, json: %{recovered: true})
    end

    assert {:ok, _} = Page.route(page.guid, "**/*", callback, timeout: @timeout)

    assert {:ok, _} = Frame.goto(frame.guid, url: "https://routing.invalid/", timeout: @timeout)
    assert {:ok, ~s({"recovered":true})} = eval(frame.guid, "() => document.body.textContent")
  end

  @tag skip: if(Application.compile_env(:playwright_ex, :ws_endpoint), do: "host-local fixture", else: false)
  test "driver globs leave unmatched requests on the network; continue preserves overrides", %{page: page, frame: frame} do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(socket)
    owner = self()
    start_supervised!({Task, fn -> serve(socket, owner) end})
    url = "http://127.0.0.1:#{port}"

    callback = fn route, request ->
      send(owner, {:intercepted, URI.parse(request.url).path})

      case URI.parse(request.url).path do
        "/continue" ->
          Route.continue(route, method: "POST", post_data: "hello", headers: %{"X-Test" => "override"})

        "/abort" ->
          Route.abort(route)

        _ ->
          assert {:error, %{reason: :timeout}} = Route.fulfill(route, body: "zero", timeout: 0)
          assert {:ok, _} = Route.fulfill(route, body: "stub")
          assert {:error, %{reason: :route_already_handled}} = Route.abort(route)
      end
    end

    assert {:ok, _} = Page.route(page.guid, "**/{continue,fulfill,abort}", callback, timeout: @timeout)
    assert {:ok, _} = Frame.goto(frame.guid, url: url <> "/continue", timeout: @timeout)
    assert_receive {:network, :POST, "/continue", headers, "hello"}
    assert {"x-test", "override"} in headers
    assert {:ok, _} = Frame.goto(frame.guid, url: url <> "/unmatched", timeout: @timeout)
    assert_receive {:network, :GET, "/unmatched", _, ""}
    refute_receive {:intercepted, "/unmatched"}
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
