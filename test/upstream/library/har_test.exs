defmodule PlaywrightEx.Library.HarTest.Http2Plug do
  # The createHttp2Server handler of "should contain http2 for http2 requests".
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/html; charset=utf-8")
    |> Plug.Conn.send_resp(200, "<h1>Hello World</h1>")
  end
end

defmodule PlaywrightEx.Library.HarTest do
  @upstream "tests/library/har.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.APIRequest
  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Tracing

  # testInfo.outputPath(): a fresh directory per test.
  setup do
    dir = Path.join(System.tmp_dir!(), "playwright_ex-har-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{output_path: &Path.join(dir, &1)}
  end

  defp page_with_har(context_factory, output_path, options \\ %{}) do
    {name, options} = Map.pop(options, :outputPath, "test.har")
    har_path = output_path.(name)
    context = context_factory.(record_har: Map.put(options, :path, har_path), ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    %{page: page, context: context, har_path: har_path}
  end

  defp get_log(%{context: context, har_path: har_path}) do
    BrowserContext.close!(context)
    har_path |> File.read!() |> JSON.decode!() |> Map.fetch!("log")
  end

  defp get_zip(%{context: context, har_path: har_path}) do
    BrowserContext.close!(context)
    parse_har(har_path)
  end

  # parseHar (tests/config/utils.ts): the zip entries by name.
  defp parse_har(file) do
    {:ok, entries} = :zip.unzip(to_charlist(file), [:memory])
    Map.new(entries, fn {name, data} -> {to_string(name), data} end)
  end

  defp read_log(path), do: path |> File.read!() |> JSON.decode!() |> Map.fetch!("log")

  defp header(headers, name), do: Enum.find(headers, &(String.downcase(&1["name"]) == name))

  defp now_ms, do: System.system_time(:millisecond)

  defp date_ms(iso) do
    {:ok, dt, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(dt, :millisecond)
  end

  # Upstream: `res.socket.destroy()`. Kill the connection's handler process.
  defp destroy_socket(_conn), do: Process.exit(self(), :kill)

  defp put_set_cookies(conn, cookies),
    do: Plug.Conn.prepend_resp_headers(conn, Enum.map(cookies, &{"set-cookie", &1}))

  defp busy_loop(until) do
    if System.system_time(:millisecond) < until, do: busy_loop(until)
  end

  test "should have version and creator", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    log = get_log(session)
    assert log["version"] == "1.2"
    assert log["creator"]["name"] == "Playwright"
    assert log["creator"]["version"] =~ (System.get_env("PW_VERSION_OVERRIDE") || PlaywrightEx.Driver.version())
  end

  test "should have browser", %{
    browser_name: browser_name,
    browser: browser,
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    log = get_log(session)

    assert log["browser"]["name"] == browser_name
    assert log["browser"]["version"] == Browser.version(browser)
  end

  test "should have pages", %{context_factory: context_factory, output_path: output_path} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, "data:text/html,<title>Hello</title>")
    # For data: load comes before domcontentloaded...
    Page.wait_for_load_state!(page, :domcontentloaded)
    log = get_log(session)
    assert length(log["pages"]) == 1
    page_entry = hd(log["pages"])
    assert page_entry["id"]
    assert page_entry["title"] == "Hello"
    assert date_ms(page_entry["startedDateTime"]) > now_ms() - 3600 * 1000
    assert page_entry["pageTimings"]["onContentLoad"] > 0
    assert page_entry["pageTimings"]["onLoad"] > 0
  end

  test "should have pages in persistent context", %{launch_persistent: launch_persistent, output_path: output_path} do
    har_path = output_path.("test.har")
    %{context: context, page: page} = launch_persistent.(record_har: %{path: har_path})
    Page.goto!(page, "data:text/html,<title>Hello</title>")
    # For data: load comes before domcontentloaded...
    Page.wait_for_load_state!(page, :domcontentloaded)
    BrowserContext.close!(context)
    log = read_log(har_path)
    assert length(log["pages"]) == 1
    page_entry = hd(log["pages"])
    assert page_entry["id"]
    assert page_entry["title"] == "Hello"
  end

  test "should include request", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    log = get_log(session)
    assert length(log["entries"]) == 1
    entry = hd(log["entries"])
    assert entry["pageref"] == hd(log["pages"])["id"]
    assert entry["request"]["url"] == server.empty_page
    assert entry["request"]["method"] == "GET"
    assert entry["request"]["httpVersion"] == "HTTP/1.1"
    assert length(entry["request"]["headers"]) > 1
    assert header(entry["request"]["headers"], "user-agent")
    assert entry["request"]["bodySize"] == 0
  end

  test "should populate entry startedDateTime from the browser", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    # The browser issues a request after a short delay, then we deliberately
    # block Node's event loop. The protocol event for the request therefore
    # queues up while Node is busy and is only processed by the harTracer after
    # the block ends. If `startedDateTime` is populated from Node's clock at
    # observation time it will land inside the busy-loop window (i.e. close to
    # `unblockedAt`); if it comes from the browser via the debugging protocol
    # it will be tied to when the browser actually sent the request.
    # (Here the test process blocks; the driver's events are processed elsewhere.)
    Page.evaluate!(page, "() => { window.builtins.setTimeout(() => { void fetch('/delayed-fetch'); }, 50); }")

    # Node processes the queued response event after waitForResponse() is set up; here events
    # are processed during the busy loop, so wait for the response before it.
    response = Page.wait_for_response(page, "**/delayed-fetch")

    block_until = now_ms() + 300
    # Busy loop to prevent Node from processing protocol events.
    busy_loop(block_until)
    unblocked_at = now_ms()

    PlaywrightEx.Promise.await!(response)
    log = get_log(session)

    entry = Enum.find(log["entries"], &String.ends_with?(&1["request"]["url"], "/delayed-fetch"))
    started_at = date_ms(entry["startedDateTime"])
    assert is_integer(started_at)
    # The recorded time should be tied to when the browser actually sent the
    # request (during the busy loop), not to when Node observed the protocol
    # event (after the busy loop).
    assert started_at < unblocked_at - 100
  end

  test "should include response", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    log = get_log(session)
    entry = hd(log["entries"])
    assert entry["response"]["status"] == 200
    assert entry["response"]["statusText"] == "OK"
    assert entry["response"]["httpVersion"] == "HTTP/1.1"
    assert length(entry["response"]["headers"]) > 1
    assert header(entry["response"]["headers"], "content-type")["value"] =~ "text/html"
  end

  test "should include redirectURL", %{context_factory: context_factory, output_path: output_path, server: server} do
    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/foo.html")
    log = get_log(session)
    assert length(log["entries"]) == 2
    entry = hd(log["entries"])
    assert entry["response"]["status"] == 302
    assert entry["response"]["redirectURL"] == server.empty_page
  end

  test "should include query params", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/har.html?name=value")
    log = get_log(session)
    assert hd(log["entries"])["request"]["queryString"] == [%{"name" => "name", "value" => "value"}]
  end

  test "should include postData", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => fetch('./post', { method: 'POST', body: 'Hello' })")
    log = get_log(session)

    assert Enum.at(log["entries"], 1)["request"]["postData"] == %{
             "mimeType" => "text/plain;charset=UTF-8",
             "params" => [],
             "text" => "Hello"
           }
  end

  test "should include binary postData", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    async () => {
      await fetch('./post', { method: 'POST', body: new Uint8Array(Array.from(Array(16).keys())) });
    }
    """)

    log = get_log(session)

    assert Enum.at(log["entries"], 1)["request"]["postData"] == %{
             "mimeType" => "application/octet-stream",
             "params" => [],
             "text" => ""
           }
  end

  test "should include form params", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    Page.set_content!(
      page,
      "<form method='POST' action='/post'><input type='text' name='foo' value='bar'><input type='number' name='baz' value='123'><input type='submit'></form>"
    )

    Page.click!(page, "input[type=submit]")
    log = get_log(session)

    assert Enum.at(log["entries"], 1)["request"]["postData"] == %{
             "mimeType" => "application/x-www-form-urlencoded",
             "params" => [
               %{"name" => "foo", "value" => "bar"},
               %{"name" => "baz", "value" => "123"}
             ],
             "text" => "foo=bar&baz=123"
           }
  end

  test "should include cookies", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    context = Page.context(page)

    BrowserContext.add_cookies!(context, [
      %{name: "name1", value: ~s("value1"), domain: "localhost", path: "/", httpOnly: true},
      %{name: "name2", value: ~s(val"ue2), domain: "localhost", path: "/", sameSite: "Lax"},
      %{name: "name3", value: "val=ue3", domain: "localhost", path: "/"},
      %{name: "name4", value: "val,ue4", domain: "localhost", path: "/"}
    ])

    Page.goto!(page, server.empty_page)
    log = get_log(session)

    assert hd(log["entries"])["request"]["cookies"] == [
             %{"name" => "name1", "value" => ~s("value1")},
             %{"name" => "name2", "value" => ~s(val"ue2)},
             %{"name" => "name3", "value" => "val=ue3"},
             %{"name" => "name4", "value" => "val,ue4"}
           ]
  end

  test "should include set-cookies", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> put_set_cookies([
        "name1=value1; HttpOnly",
        ~s(name2="value2"),
        "name3=value4; Path=/; Domain=example.com; Max-Age=1500"
      ])
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.empty_page)
    log = get_log(session)
    cookies = hd(log["entries"])["response"]["cookies"]
    assert Enum.at(cookies, 0) == %{"name" => "name1", "value" => "value1", "httpOnly" => true}
    assert Enum.at(cookies, 1) == %{"name" => "name2", "value" => ~s("value2")}
    assert date_ms(Enum.at(cookies, 2)["expires"]) > now_ms()
  end

  test "should include set-cookies with lowercase attributes", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> put_set_cookies(["name=value; path=/; httponly; secure; samesite=Lax"])
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.empty_page)
    log = get_log(session)
    cookies = hd(log["entries"])["response"]["cookies"]

    assert Enum.at(cookies, 0) == %{
             "name" => "name",
             "value" => "value",
             "path" => "/",
             "httpOnly" => true,
             "secure" => true,
             "sameSite" => "Lax"
           }
  end

  test "should skip invalid Expires", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> put_set_cookies(["name=value;Expires=Sat Sep 14 01:02:27 CET 2024"])
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.empty_page)
    log = get_log(session)
    cookies = hd(log["entries"])["response"]["cookies"]
    assert Enum.at(cookies, 0) == %{"name" => "name", "value" => "value"}
  end

  @tag skip:
         if(@browser_name == "webkit",
           do: "upstream fixme: We get \"name1=val, ue1, name2=val, ue2\" as a header value"
         )
  test "should include set-cookies with comma", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    # it.fixme(browserName === 'webkit', 'We get "name1=val, ue1, name2=val, ue2" as a header value')
    %{page: page} = session = page_with_har(context_factory, output_path)

    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> put_set_cookies(["name1=val, ue1", "name2=val, ue2"])
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.empty_page)
    log = get_log(session)
    cookies = hd(log["entries"])["response"]["cookies"]
    assert Enum.at(cookies, 0) == %{"name" => "name1", "value" => "val, ue1"}
    assert Enum.at(cookies, 1) == %{"name" => "name2", "value" => "val, ue2"}
  end

  test "should include secure set-cookies", %{
    context_factory: context_factory,
    output_path: output_path,
    https_server: https_server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)

    TestServer.set_route(https_server, "/empty.html", fn conn ->
      conn
      |> put_set_cookies(["name1=value1; Secure"])
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, https_server.empty_page)
    log = get_log(session)
    cookies = hd(log["entries"])["response"]["cookies"]
    assert Enum.at(cookies, 0) == %{"name" => "name1", "value" => "value1", "secure" => true}
  end

  test "should record request overrides", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)

    Page.route!(page, "**/foo", fn route ->
      Route.fallback(route,
        url: server.empty_page,
        method: "POST",
        headers:
          Map.merge(PlaywrightEx.Request.headers(Route.request(route)), %{
            "content-type" => "text/plain",
            "cookie" => "foo=bar",
            "custom" => "value"
          }),
        post_data: "Hi!"
      )
    end)

    Page.goto!(page, server.prefix <> "/foo")
    log = get_log(session)
    request = hd(log["entries"])["request"]
    assert request["url"] == server.empty_page
    assert request["method"] == "POST"
    assert %{"name" => "custom", "value" => "value"} in request["headers"]
    assert request["cookies"] == []
    assert request["postData"] == %{"mimeType" => "text/plain", "params" => [], "text" => "Hi!"}
  end

  test "should include content @smoke", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/har.html")
    Page.evaluate!(page, "() => fetch('/pptr.png').then(r => r.arrayBuffer())")
    log = get_log(session)
    [content0, content1, content2 | _] = Enum.map(log["entries"], & &1["response"]["content"])

    assert content0["encoding"] == nil
    assert content0["mimeType"] == "text/html; charset=utf-8"
    assert content0["text"] =~ "HAR Page"
    assert content0["size"] >= 96
    assert content0["compression"] == 0

    assert content1["encoding"] == nil
    assert content1["mimeType"] == "text/css; charset=utf-8"
    assert content1["text"] =~ "pink"
    assert content1["size"] >= 37
    assert content1["compression"] == 0

    assert content2["encoding"] == "base64"
    assert content2["mimeType"] == "image/png"
    assert byte_size(Base.decode64!(content2["text"])) > 0
    assert content2["size"] >= 6000
    assert content2["compression"] == 0
  end

  test "should use attach mode for zip extension", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path, %{outputPath: "test.har.zip"})
    Page.goto!(page, server.prefix <> "/har.html")
    Page.evaluate!(page, "() => fetch('/pptr.png').then(r => r.arrayBuffer())")
    zip = get_zip(session)
    log = zip |> Map.fetch!("har.har") |> JSON.decode!() |> Map.fetch!("log")
    assert hd(log["entries"])["response"]["content"]["text"] == nil
    assert Map.fetch!(zip, "75841480e2606c03389077304342fac2c58ccb1b.html") =~ "HAR Page"
  end

  test "should omit content", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path, %{content: "omit", outputPath: "test.har"})
    Page.goto!(page, server.prefix <> "/har.html")
    Page.evaluate!(page, "() => fetch('/pptr.png').then(r => r.arrayBuffer())")
    log = get_log(session)
    assert hd(log["entries"])["response"]["content"]["text"] == nil
    assert hd(log["entries"])["response"]["content"]["_file"] == nil
  end

  test "should omit content legacy", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path, %{omitContent: true, outputPath: "test.har"})
    Page.goto!(page, server.prefix <> "/har.html")
    Page.evaluate!(page, "() => fetch('/pptr.png').then(r => r.arrayBuffer())")
    log = get_log(session)
    assert hd(log["entries"])["response"]["content"]["text"] == nil
    assert hd(log["entries"])["response"]["content"]["_file"] == nil
  end

  test "should attach content", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} =
      session = page_with_har(context_factory, output_path, %{content: "attach", outputPath: "test.har.zip"})

    Page.goto!(page, server.prefix <> "/har.html")
    Page.evaluate!(page, "() => fetch('/pptr.png').then(r => r.arrayBuffer())")
    zip = get_zip(session)
    log = zip |> Map.fetch!("har.har") |> JSON.decode!() |> Map.fetch!("log")
    [content0, content1, content2 | _] = Enum.map(log["entries"], & &1["response"]["content"])

    assert content0["encoding"] == nil
    assert content0["mimeType"] == "text/html; charset=utf-8"
    assert content0["_file"] =~ "75841480e2606c03389077304342fac2c58ccb1b"
    assert content0["size"] >= 96
    assert content0["compression"] == 0

    assert content1["encoding"] == nil
    assert content1["mimeType"] == "text/css; charset=utf-8"
    assert content1["_file"] =~ "79f739d7bc88e80f55b9891a22bf13a2b4e18adb"
    assert content1["size"] >= 37
    assert content1["compression"] == 0

    assert content2["encoding"] == nil
    assert content2["mimeType"] == "image/png"
    assert content2["_file"] =~ "a4c3a18f0bb83f5d9fe7ce561e065c36205762fa"
    assert content2["size"] >= 6000
    assert content2["compression"] == 0

    assert Map.fetch!(zip, "75841480e2606c03389077304342fac2c58ccb1b.html") =~ "HAR Page"
    assert Map.fetch!(zip, "79f739d7bc88e80f55b9891a22bf13a2b4e18adb.css") =~ "pink"
    assert byte_size(Map.fetch!(zip, "a4c3a18f0bb83f5d9fe7ce561e065c36205762fa.png")) == content2["size"]
  end

  test "should filter by glob", %{context_factory: context_factory, output_path: output_path, server: server} do
    har_path = output_path.("test.har")

    context =
      context_factory.(
        base_url: server.prefix,
        record_har: %{path: har_path, urlFilter: "/*.css"},
        ignore_https_errors: true
      )

    page = BrowserContext.new_page!(context)
    Page.goto!(page, "/har.html")
    BrowserContext.close!(context)
    log = read_log(har_path)
    assert length(log["entries"]) == 1
    assert String.ends_with?(hd(log["entries"])["request"]["url"], "one-style.css")
  end

  test "should filter by regexp", %{context_factory: context_factory, output_path: output_path, server: server} do
    har_path = output_path.("test.har")
    context = context_factory.(record_har: %{path: har_path, urlFilter: ~r/HAR.X?HTML/i}, ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/har.html")
    BrowserContext.close!(context)
    log = read_log(har_path)
    assert length(log["entries"]) == 1
    assert String.ends_with?(hd(log["entries"])["request"]["url"], "har.html")
  end

  test "should include sizes", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server,
    asset: asset
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/har.html")
    log = get_log(session)
    assert length(log["entries"]) == 2
    [entry0, entry1] = log["entries"]
    assert String.ends_with?(entry0["request"]["url"], "har.html")
    assert entry0["request"]["headersSize"] >= 100
    assert entry0["response"]["bodySize"] == File.stat!(asset.("har.html")).size
    assert entry0["response"]["headersSize"] >= 100
    assert entry0["response"]["_transferSize"] >= 250

    assert String.ends_with?(entry1["request"]["url"], "one-style.css")
    assert entry1["response"]["bodySize"] == File.stat!(asset.("one-style.css")).size
    assert entry1["response"]["headersSize"] >= 100
    assert entry1["response"]["_transferSize"] >= 150
  end

  test "should work with gzip compression", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    TestServer.enable_gzip(server, "/simplezip.json")
    response = Page.goto!(page, server.prefix <> "/simplezip.json")
    assert Response.headers(response)["content-encoding"] == "gzip"
    log = get_log(session)
    assert length(log["entries"]) == 1
    assert hd(log["entries"])["response"]["content"]["compression"] > 4000
  end

  test "should calculate time", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/har.html")
    log = get_log(session)
    assert hd(log["entries"])["time"] > 0
  end

  test "should return receive time", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/har.html")
    log = get_log(session)
    assert hd(log["entries"])["timings"]["receive"] > 0
  end

  test "should report the correct _transferSize with PNG files", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server,
    asset: asset
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <img src="#{server.prefix}/pptr.png" />
    """)

    log = get_log(session)
    assert Enum.at(log["entries"], 1)["response"]["_transferSize"] > File.stat!(asset.("pptr.png")).size
  end

  test "should have -1 _transferSize when its a failed request", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)

    TestServer.set_route(server, "/one-style.css", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/css") |> destroy_socket()
    end)

    me = self()
    Page.on(page, :request_failed, fn request -> send(me, {:failed_request, request}) end)
    Page.goto!(page, server.prefix <> "/har.html")
    log = get_log(session)
    assert String.ends_with?(Enum.at(log["entries"], 1)["request"]["url"], "/one-style.css")
    assert Enum.at(log["entries"], 1)["response"]["_transferSize"] == -1
  end

  test "should record failed request headers", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    TestServer.set_route(server, "/har.html", &destroy_socket/1)
    Page.goto(page, server.prefix <> "/har.html")
    log = get_log(session)
    assert hd(log["entries"])["response"]["_failureText"]
    request = hd(log["entries"])["request"]
    assert String.ends_with?(request["url"], "/har.html")
    assert request["method"] == "GET"
    assert Enum.any?(request["headers"], &match?(%{"name" => "User-Agent"}, &1))
  end

  test "should record failed request overrides", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    TestServer.set_route(server, "/empty.html", &destroy_socket/1)

    Page.route!(page, "**/foo", fn route ->
      Route.fallback(route,
        url: server.empty_page,
        method: "POST",
        headers:
          Map.merge(PlaywrightEx.Request.headers(Route.request(route)), %{
            "content-type" => "text/plain",
            "cookie" => "foo=bar",
            "custom" => "value"
          }),
        post_data: "Hi!"
      )
    end)

    Page.goto(page, server.prefix <> "/foo")
    log = get_log(session)
    assert hd(log["entries"])["response"]["_failureText"]
    request = hd(log["entries"])["request"]
    assert request["url"] == server.empty_page
    assert request["method"] == "POST"
    assert %{"name" => "custom", "value" => "value"} in request["headers"]
    assert request["cookies"] == []
    assert request["postData"] == %{"mimeType" => "text/plain", "params" => [], "text" => "Hi!"}
  end

  test "should report the correct request body size", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    TestServer.set_route(server, "/api", &Plug.Conn.send_resp(&1, 200, ""))
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    Page.expect_response!(page, server.prefix <> "/api1", fn ->
      Page.evaluate!(page, """
      () => {
        void fetch('/api1', {
          method: 'POST',
          body: 'abc123'
        });
      }
      """)
    end)

    log = get_log(session)
    assert Enum.at(log["entries"], 1)["request"]["bodySize"] == 6
  end

  test "should report the correct request body size when the bodySize is 0", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    TestServer.set_route(server, "/api", &Plug.Conn.send_resp(&1, 200, ""))
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    Page.expect_response!(page, server.prefix <> "/api2", fn ->
      Page.evaluate!(page, """
      () => {
        void fetch('/api2', {
          method: 'POST',
          body: ''
        });
      }
      """)
    end)

    log = get_log(session)
    assert Enum.at(log["entries"], 1)["request"]["bodySize"] == 0
  end

  test "should report the correct response body size when the bodySize is 0", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    %{page: page} = session = page_with_har(context_factory, output_path)
    response = Page.goto!(page, server.empty_page)
    Response.finished!(response)
    log = get_log(session)
    assert hd(log["entries"])["response"]["bodySize"] == 0
  end

  test "should have popup requests", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a target=_blank rel=noopener href="/one-style.html">yo</a>))
    popup = Page.expect_popup!(page, fn -> Page.click!(page, "a") end)
    Page.wait_for_load_state!(popup)
    log = get_log(session)

    assert length(log["pages"]) == 2

    entries = Enum.filter(log["entries"], &(&1["pageref"] == Enum.at(log["pages"], 1)["id"]))
    assert length(entries) == 2
    [entry0, entry1] = entries
    assert entry0["request"]["url"] == server.prefix <> "/one-style.html"
    assert entry0["response"]["status"] == 200
    assert entry1["request"]["url"] == server.prefix <> "/one-style.css"
    assert entry1["response"]["status"] == 200
  end

  test "should not contain internal pages", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn |> put_set_cookies(["name=value"]) |> Plug.Conn.send_resp(200, "")
    end)

    %{page: page, context: context} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)

    cookies = BrowserContext.cookies!(context)
    assert length(cookies) == 1
    # Get storage state, this create internal page.
    BrowserContext.storage_state!(context)

    log = get_log(session)
    assert length(log["pages"]) == 1
  end

  test "should have connection details", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    log = get_log(session)

    %{"serverIPAddress" => server_ip_address, "_serverPort" => port, "_securityDetails" => security_details} =
      hd(log["entries"])

    assert server_ip_address =~ ~r/^127\.0\.0\.1|\[::1\]/
    assert port == server.port
    assert security_details == %{}
  end

  @tag skip: if(@browser_name == "webkit" and match?({:win32, _}, :os.type()), do: "upstream fail: webkit on Windows")
  test "should have security details", %{
    context_factory: context_factory,
    output_path: output_path,
    https_server: https_server,
    browser_name: browser_name
  } do
    # it.fail(browserName === 'webkit' && platform === 'win32' && channel !== 'webkit-wsl');
    # it.skip(isFrozenWebkit);  -- not ported: no frozen WebKit
    %{page: page, context: context} = session = page_with_har(context_factory, output_path)
    api_har_path = output_path.("api.har")
    Tracing.start_har!(APIRequestContext.tracing(BrowserContext.request(context)), api_har_path)
    Page.goto!(page, https_server.empty_page)
    APIRequestContext.get!(Page.request(page), https_server.empty_page)
    Tracing.stop_har!(APIRequestContext.tracing(BrowserContext.request(context)))
    log = get_log(session)
    assert length(log["entries"]) == 1

    %{"serverIPAddress" => server_ip_address, "_serverPort" => port, "_securityDetails" => security_details} =
      hd(log["entries"])

    assert server_ip_address =~ ~r/^127\.0\.0\.1|\[::1\]/
    assert port == https_server.port

    if browser_name == "webkit",
      do:
        assert(
          security_details == %{
            "protocol" => "TLS 1.3",
            "subjectName" => "playwright-test",
            "validFrom" => 1_691_708_270,
            "validTo" => 2_007_068_270
          }
        ),
      else:
        assert(
          security_details == %{
            "issuer" => "playwright-test",
            "protocol" => "TLS 1.3",
            "subjectName" => "playwright-test",
            "validFrom" => 1_691_708_270,
            "validTo" => 2_007_068_270
          }
        )

    api_log = read_log(api_har_path)
    assert length(api_log["entries"]) == 1

    assert hd(api_log["entries"])["_securityDetails"] == %{
             "issuer" => "playwright-test",
             "protocol" => "TLSv1.3",
             "subjectName" => "playwright-test",
             "validFrom" => 1_691_708_270,
             "validTo" => 2_007_068_270
           }
  end

  test "should have connection details for redirects", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server,
    browser_name: browser_name
  } do
    TestServer.set_redirect(server, "/foo.html", "/empty.html")
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/foo.html")
    log = get_log(session)
    assert length(log["entries"]) == 2

    details_foo = Enum.at(log["entries"], 0)

    if browser_name == "webkit" do
      assert details_foo["serverIPAddress"] == nil
      assert details_foo["_serverPort"] == nil
    else
      assert details_foo["serverIPAddress"] =~ ~r/^127\.0\.0\.1|\[::1\]/
      assert details_foo["_serverPort"] == server.port
    end

    details_empty = Enum.at(log["entries"], 1)
    assert details_empty["serverIPAddress"] =~ ~r/^127\.0\.0\.1|\[::1\]/
    assert details_empty["_serverPort"] == server.port
  end

  test "should have connection details for failed requests", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    TestServer.set_route(server, "/one-style.css", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/css") |> destroy_socket()
    end)

    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/one-style.html")
    log = get_log(session)
    %{"serverIPAddress" => server_ip_address, "_serverPort" => port} = hd(log["entries"])
    assert server_ip_address =~ ~r/^127\.0\.0\.1|\[::1\]/
    assert port == server.port
  end

  test "should return server address directly from response", %{context_factory: context_factory, server: server} do
    page = BrowserContext.new_page!(context_factory.([]))
    response = Page.goto!(page, server.empty_page)
    %{ipAddress: ip_address, port: port} = Response.server_addr!(response)
    assert ip_address =~ ~r/^127\.0\.0\.1|\[::1\]/
    assert port == server.port
  end

  test "should return security details directly from response", %{
    context_factory: context_factory,
    https_server: https_server,
    browser_name: browser_name
  } do
    context = context_factory.(ignore_https_errors: true)
    page = BrowserContext.new_page!(context)
    response = Page.goto!(page, https_server.empty_page)
    security_details = Response.security_details!(response)

    cond do
      browser_name == "webkit" and match?({:win32, _}, :os.type()) ->
        # WebKit on Windows does not surface the TLS protocol.
        assert Map.delete(security_details, :protocol) == %{
                 subjectName: "playwright-test",
                 validFrom: 1_691_708_270,
                 validTo: 2_007_068_270
               }

      browser_name == "webkit" ->
        assert security_details == %{
                 protocol: "TLS 1.3",
                 subjectName: "playwright-test",
                 validFrom: 1_691_708_270,
                 validTo: 2_007_068_270
               }

      true ->
        assert security_details == %{
                 issuer: "playwright-test",
                 protocol: "TLS 1.3",
                 subjectName: "playwright-test",
                 validFrom: 1_691_708_270,
                 validTo: 2_007_068_270
               }
    end
  end

  test "should contain http2 for http2 requests", %{context_factory: context_factory, output_path: output_path} do
    # createHttp2Server(await TestServer.certOptions()): Bandit negotiates h2 over TLS.
    {:ok, http2_server} =
      Bandit.start_link(
        plug: __MODULE__.Http2Plug,
        scheme: :https,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false,
        thousand_island_options: [transport_options: TestServer.cert_options()]
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(http2_server)

    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, "https://localhost:#{port}")
    log = get_log(session)
    assert hd(log["entries"])["request"]["httpVersion"] == "HTTP/2.0"
    assert hd(log["entries"])["response"]["httpVersion"] == "HTTP/2.0"
    assert hd(log["entries"])["response"]["content"]["text"] == "<h1>Hello World</h1>"
    Supervisor.stop(http2_server)
  end

  @tag skip: "upstream skip: headless browsers, except firefox, do not request favicons"
  test "should filter favicon and favicon redirects"

  test "should have different hars for concurrent contexts", %{
    context_factory: context_factory,
    output_path: output_path
  } do
    session0 = page_with_har(context_factory, output_path, %{outputPath: "test-0.har"})
    Page.goto!(session0.page, "data:text/html,<title>Zero</title>")
    Page.wait_for_load_state!(session0.page, :domcontentloaded)

    session1 = page_with_har(context_factory, output_path, %{outputPath: "test-1.har"})
    Page.goto!(session1.page, "data:text/html,<title>One</title>")
    Page.wait_for_load_state!(session1.page, :domcontentloaded)

    # Trigger flushing on the server and ensure they are not racing to same
    # location. NB: Run this test with --repeat-each 10.
    [log0, log1] =
      [session0, session1]
      |> Enum.map(&Task.async(fn -> get_log(&1) end))
      |> Task.await_many(:infinity)

    assert length(log0["pages"]) == 1
    page_entry = hd(log0["pages"])
    assert page_entry["title"] == "Zero"

    assert length(log1["pages"]) == 1
    page_entry = hd(log1["pages"])
    assert page_entry["id"] != hd(log0["pages"])["id"]
    assert page_entry["title"] == "One"
  end

  test "should exclude API request", %{context_factory: context_factory, output_path: output_path, server: server} do
    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    APIRequestContext.get!(Page.request(page), server.prefix <> "/simple.json")
    log = get_log(session)
    assert Enum.map(log["entries"], & &1["request"]["url"]) == [server.empty_page]
  end

  test "should correctly record API request cookies with equals sign in value", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    context = context_factory.([])
    har_path = output_path.("request.har")
    Tracing.start_har!(APIRequestContext.tracing(BrowserContext.request(context)), har_path)
    url = server.prefix <> "/simple.json"
    APIRequestContext.get!(BrowserContext.request(context), url, headers: %{"cookie" => "token=abc=xyz; other=val"})
    Tracing.stop_har!(APIRequestContext.tracing(BrowserContext.request(context)))
    BrowserContext.close!(context)
    log = read_log(har_path)

    assert hd(log["entries"])["request"]["cookies"] == [
             %{"name" => "token", "value" => "abc=xyz"},
             %{"name" => "other", "value" => "val"}
           ]
  end

  test "should respect minimal mode for API Requests", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    context = context_factory.([])
    har_path = output_path.("request.har")
    Tracing.start_har!(APIRequestContext.tracing(BrowserContext.request(context)), har_path, mode: :minimal)
    url = server.prefix <> "/simple.json"

    APIRequestContext.post!(BrowserContext.request(context), url,
      headers: %{"cookie" => "a=b; c=d"},
      data: %{foo: "bar"}
    )

    Tracing.stop_har!(APIRequestContext.tracing(BrowserContext.request(context)))
    BrowserContext.close!(context)
    %{"entries" => entries} = read_log(har_path)
    assert [entry] = entries
    assert entry["timings"] == %{"receive" => -1, "send" => -1, "wait" => -1}
    refute Map.has_key?(entry, "serverIPAddress")
    refute Map.has_key?(entry, "_serverPort")
    assert entry["request"]["cookies"] == []
    assert entry["request"]["bodySize"] == -1
    assert entry["response"]["bodySize"] == -1
  end

  test "should include redirects from API request", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    TestServer.set_redirect(server, "/redirect-me", "/simple.json")
    context = context_factory.([])
    har_path = output_path.("request.har")
    Tracing.start_har!(APIRequestContext.tracing(BrowserContext.request(context)), har_path)

    APIRequestContext.post!(BrowserContext.request(context), server.prefix <> "/redirect-me",
      headers: %{"cookie" => "a=b; c=d"},
      data: %{foo: "bar"}
    )

    Tracing.stop_har!(APIRequestContext.tracing(BrowserContext.request(context)))
    BrowserContext.close!(context)
    log = read_log(har_path)
    assert length(log["entries"]) == 2
    [redirect, json] = log["entries"]
    assert redirect["request"]["url"] == server.prefix <> "/redirect-me"
    assert json["request"]["url"] == server.prefix <> "/simple.json"
    assert redirect["response"]["bodySize"] == -1
    assert redirect["response"]["content"]["size"] == -1
    assert redirect["timings"] != nil
    assert json["timings"] != nil
  end

  test "should not hang on resources served from cache", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server,
    browser_name: browser_name
  } do
    TestServer.set_route(server, "/one-style.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=10031518")
      |> Plug.Conn.send_resp(200, "body { background: red }")
    end)

    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/har.html")
    Page.goto!(page, server.prefix <> "/har.html")
    log = get_log(session)
    entries = Enum.filter(log["entries"], &String.ends_with?(&1["request"]["url"], "one-style.css"))
    # In firefox no request events are fired for cached resources.
    # (isBidi: we do not run BiDi.)
    if browser_name == "firefox",
      do: assert(length(entries) == 1),
      else: assert(length(entries) == 2)
  end

  test "should not hang on slow chunked response", %{
    browser_name: browser_name,
    browser: browser,
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    TestServer.set_route(server, "/empty.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
      <script>
          let receivedFirstData = new Promise(f => {
            setTimeout(() =>  {
              var x = new XMLHttpRequest();
              x.open("GET", "slow.txt");
              x.onprogress = () => f();
              x.send();
            }, 0);
          });
          </script>
      """)
    end)

    TestServer.set_route(server, "/slow.txt", fn conn ->
      # 'Content-length': '2023' next to chunked encoding  -- not ported: Plug sends chunked without it
      conn = conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_chunked(200)
      {:ok, conn} = Plug.Conn.chunk(conn, "begin")
      # The response never ends.
      Process.sleep(:infinity)
      conn
    end)

    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => window.receivedFirstData")
    log = get_log(session)

    assert log["browser"]["name"] == browser_name
    assert log["browser"]["version"] == Browser.version(browser)
  end

  test "should close the context when saving the har fails", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    file_path = output_path.("not-a-directory")
    File.write!(file_path, "data")
    context = context_factory.(record_har: %{path: Path.join(file_path, "test.har")})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    me = self()
    BrowserContext.on(context, :close, fn _ -> send(me, :closed) end)
    assert {:error, e} = BrowserContext.close(context)
    assert Exception.message(e) =~ ~r/ENOTDIR|ENOENT|EEXIST/
    assert_receive :closed
    BrowserContext.close!(context)
  end

  # it.slow()
  @tag timeout: @slow_timeout
  @tag skip: if(@browser_name != "chromium", do: "upstream skip: serializer is browser-agnostic; one browser is enough")
  test "should support HAR larger than 512MB", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server
  } do
    # it.skip(browserName !== 'chromium', 'serializer is browser-agnostic; one browser is enough');
    # annotation: https://github.com/microsoft/playwright/issues/36707
    har_path = output_path.("test.har")
    context = context_factory.([])
    Tracing.start_har!(APIRequestContext.tracing(BrowserContext.request(context)), har_path)

    # 30 x 20MB textual responses push the HAR JSON past V8's ~512MB max
    # string length. Each body still fits in a single string; only the
    # aggregate would overflow the previous tokens.join('').
    body = String.duplicate("a", 20 * 1024 * 1024)

    TestServer.set_route(server, "/large", fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/plain") |> Plug.Conn.send_resp(200, body)
    end)

    for _ <- 1..30, do: APIRequestContext.get!(BrowserContext.request(context), "#{server.prefix}/large")
    Tracing.stop_har!(APIRequestContext.tracing(BrowserContext.request(context)))
    BrowserContext.close!(context)

    %File.Stat{size: size} = File.stat!(har_path)
    assert size > 512 * 1024 * 1024

    # Reading the whole file as a string would re-hit V8's limit, so
    # sample the head and tail to verify structural sanity.
    {:ok, fd} = :file.open(har_path, [:read, :binary, :raw])
    {:ok, head} = :file.pread(fd, 0, 64)
    {:ok, tail} = :file.pread(fd, size - 64, 64)
    :ok = :file.close(fd)
    assert head =~ ~r/^\{\s*"log"\s*:\s*\{/
    assert tail =~ ~r/\}\s*\}\s*$/
  end

  test "should record resource type", %{
    context_factory: context_factory,
    output_path: output_path,
    server: server,
    asset: asset
  } do
    TestServer.set_route(server, "/resource-types.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, """
        <link rel="stylesheet" href="/resource-type-stylesheet.css">
        <script src="/resource-type-script.js"></script>
        <img src="/resource-type-image.png">
      """)
    end)

    TestServer.set_route(server, "/resource-type-stylesheet.css", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/css")
      |> Plug.Conn.send_resp(200, """
        @font-face {
          font-family: 'iconfont';
          src: url('/resource-type-font.woff2') format('woff2');
        }
        body { font-family: 'iconfont'; }
      """)
    end)

    TestServer.set_route(server, "/resource-type-font.woff2", fn conn ->
      TestServer.serve_file(server, conn, asset.("webfont/iconfont.woff2"))
    end)

    TestServer.set_route(server, "/resource-type-script.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.send_resp(200, "window.__loaded = true;")
    end)

    TestServer.set_route(server, "/resource-type-image.png", fn conn ->
      TestServer.serve_file(server, conn, asset.("pptr.png"))
    end)

    %{page: page} = session = page_with_har(context_factory, output_path)
    Page.goto!(page, server.prefix <> "/resource-types.html")
    Page.evaluate!(page, "() => fetch('/resource-type-fetch').catch(() => {})")

    Page.evaluate!(page, """
    () => new Promise(resolve => {
      const xhr = new XMLHttpRequest();
      xhr.open('GET', '/resource-type-xhr');
      xhr.onloadend = () => resolve();
      xhr.send();
    })
    """)

    log = get_log(session)

    type_for_url = Map.new(log["entries"], &{&1["request"]["url"], &1["_resourceType"]})

    expected = %{
      (server.prefix <> "/resource-types.html") => "document",
      (server.prefix <> "/resource-type-stylesheet.css") => "stylesheet",
      (server.prefix <> "/resource-type-script.js") => "script",
      (server.prefix <> "/resource-type-image.png") => "image",
      (server.prefix <> "/resource-type-font.woff2") => "font",
      (server.prefix <> "/resource-type-fetch") => "fetch",
      (server.prefix <> "/resource-type-xhr") => "xhr"
    }

    assert Map.take(type_for_url, Map.keys(expected)) == expected
  end

  describe "tracing.startHar" do
    test "should record a HAR with options", %{
      context_factory: context_factory,
      output_path: output_path,
      server: server
    } do
      context = context_factory.([])
      har_path = output_path.("tracing.har")
      Tracing.start_har!(BrowserContext.tracing(context), har_path, mode: :minimal, url_filter: "**/one-style.css")
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/one-style.html")
      Tracing.stop_har!(BrowserContext.tracing(context))
      BrowserContext.close!(context)

      log = read_log(har_path)
      urls = Enum.map(log["entries"], & &1["request"]["url"])
      assert urls == [server.prefix <> "/one-style.css"]
      # Minimal mode drops body sizes.
      assert hd(log["entries"])["request"]["bodySize"] == -1
    end

    test "should record a HAR for a context APIRequestContext", %{
      context_factory: context_factory,
      output_path: output_path,
      server: server
    } do
      context = context_factory.([])
      har_path = output_path.("request.har")
      Tracing.start_har!(APIRequestContext.tracing(BrowserContext.request(context)), har_path)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      url = server.prefix <> "/simple.json"

      response =
        APIRequestContext.post!(BrowserContext.request(context), url,
          headers: %{"cookie" => "a=b; c=d"},
          data: %{foo: "bar"}
        )

      response_body = APIResponse.body!(response)
      Tracing.stop_har!(APIRequestContext.tracing(BrowserContext.request(context)))
      BrowserContext.close!(context)

      log = read_log(har_path)
      assert length(log["entries"]) == 1
      entry = hd(log["entries"])
      assert entry["request"]["url"] == url
      assert entry["request"]["method"] == "POST"
      assert entry["request"]["httpVersion"] == "HTTP/1.1"
      assert entry["request"]["cookies"] == [%{"name" => "a", "value" => "b"}, %{"name" => "c", "value" => "d"}]
      header = fn headers, name -> Enum.find(headers, &(String.downcase(&1["name"]) == name)) end
      assert length(entry["request"]["headers"]) > 1
      assert header.(entry["request"]["headers"], "user-agent")
      assert header.(entry["request"]["headers"], "content-type")["value"] == "application/json"
      assert header.(entry["request"]["headers"], "content-length")["value"] == "13"
      assert entry["request"]["bodySize"] == 13

      assert entry["response"]["status"] == 200
      assert header.(entry["response"]["headers"], "content-type")["value"] =~ "application/json"
      assert entry["response"]["content"]["size"] == 15
      assert entry["response"]["content"]["text"] == response_body
      assert entry["response"]["bodySize"] == 15

      assert entry["time"] > 0
      assert %{"blocked" => -1} = entry["timings"]

      for key <- ~w(connect dns receive send ssl wait),
          do: assert(is_number(entry["timings"][key]))

      assert entry["serverIPAddress"] != nil
      assert entry["_serverPort"] == server.port
    end

    test "should include pages", %{context_factory: context_factory, output_path: output_path, server: server} do
      context = context_factory.([])
      har_path = output_path.("tracing.har")
      Tracing.start_har!(BrowserContext.tracing(context), har_path)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/title.html")
      page2 = BrowserContext.new_page!(context)
      Page.goto!(page2, server.prefix <> "/empty.html")
      # Close the page before stopping - it should still be in the har.
      Page.close!(page)
      Tracing.stop_har!(BrowserContext.tracing(context))
      BrowserContext.close!(context)

      log = read_log(har_path)
      assert length(log["pages"]) == 2
      assert Enum.at(log["pages"], 0)["title"] == "Woof-Woof"
      assert Enum.at(log["pages"], 1)["title"] == ""
    end

    test "should record a zipped HAR for APIRequestContext", %{
      playwright: playwright,
      output_path: output_path,
      server: server
    } do
      request = APIRequest.new_context!(Playwright.request(playwright))
      har_path = output_path.("tracing.har.zip")
      Tracing.start_har!(APIRequestContext.tracing(request), har_path, content: :attach)
      APIRequestContext.get!(request, server.prefix <> "/simple.json")
      Tracing.stop_har!(APIRequestContext.tracing(request))
      APIRequestContext.dispose!(request)

      resources = parse_har(har_path)
      log = resources |> Map.fetch!("har.har") |> JSON.decode!() |> Map.fetch!("log")
      assert Enum.any?(log["entries"], &(&1["request"]["url"] == server.prefix <> "/simple.json"))
    end

    test "should record correct cookie expires for APIRequestContext", %{
      playwright: playwright,
      output_path: output_path,
      server: server
    } do
      TestServer.set_route(server, "/set-cookie", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "name=value; Expires=Tue, 01 Jan 2030 00:00:00 GMT")
        |> Plug.Conn.send_resp(200, "hello")
      end)

      request = APIRequest.new_context!(Playwright.request(playwright))
      har_path = output_path.("api.har.zip")
      Tracing.start_har!(APIRequestContext.tracing(request), har_path, content: :attach)
      APIRequestContext.get!(request, server.prefix <> "/set-cookie")
      Tracing.stop_har!(APIRequestContext.tracing(request))
      APIRequestContext.dispose!(request)

      resources = parse_har(har_path)
      log = resources |> Map.fetch!("har.har") |> JSON.decode!() |> Map.fetch!("log")
      entry = Enum.find(log["entries"], &String.ends_with?(&1["request"]["url"], "/set-cookie"))
      cookie = Enum.find(entry["response"]["cookies"], &(&1["name"] == "name"))
      {:ok, expires, _} = DateTime.from_iso8601(cookie["expires"])
      assert expires.year == 2030
    end

    test "should record mixed-case request content-type for APIRequestContext", %{
      playwright: playwright,
      output_path: output_path,
      server: server
    } do
      TestServer.set_route(server, "/post", &Plug.Conn.send_resp(&1, 200, "ok"))
      request = APIRequest.new_context!(Playwright.request(playwright))
      har_path = output_path.("api-post.har.zip")
      Tracing.start_har!(APIRequestContext.tracing(request), har_path, content: :attach)

      APIRequestContext.post!(request, server.prefix <> "/post",
        headers: %{"Content-Type" => "application/json"},
        data: {:binary, ~s({"a":1})}
      )

      Tracing.stop_har!(APIRequestContext.tracing(request))
      APIRequestContext.dispose!(request)

      resources = parse_har(har_path)
      log = resources |> Map.fetch!("har.har") |> JSON.decode!() |> Map.fetch!("log")
      entry = Enum.find(log["entries"], &String.ends_with?(&1["request"]["url"], "/post"))
      assert entry["request"]["postData"]["mimeType"] == "application/json"
    end

    test "should record a HAR with resourcesDir", %{
      context_factory: context_factory,
      output_path: output_path,
      server: server
    } do
      context = context_factory.([])
      har_path = output_path.("tracing.har")
      resources_dir = output_path.("har-resources")
      Tracing.start_har!(BrowserContext.tracing(context), har_path, content: :attach, resources_dir: resources_dir)
      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.prefix <> "/one-style.html")
      Tracing.stop_har!(BrowserContext.tracing(context))
      BrowserContext.close!(context)

      log = read_log(har_path)
      style_entry = Enum.find(log["entries"], &String.ends_with?(&1["request"]["url"], "/one-style.css"))
      file = style_entry["response"]["content"]["_file"]
      assert file
      # _file is relative to the har file directory.
      resource_path = Path.join(Path.dirname(har_path), file)
      assert String.starts_with?(resource_path, resources_dir <> "/")
      assert File.exists?(resource_path)
      assert File.read!(resource_path) =~ "pink"
    end

    test "should reject resourcesDir together with a .zip har file", %{
      context_factory: context_factory,
      output_path: output_path
    } do
      context = context_factory.([])
      har_path = output_path.("tracing.har.zip")
      resources_dir = output_path.("har-resources")

      assert {:error, e} =
               Tracing.start_har(BrowserContext.tracing(context), har_path,
                 content: :attach,
                 resources_dir: resources_dir
               )

      assert Exception.message(e) =~ ~r/resourcesDir option is not compatible with a \.zip har file/
      BrowserContext.close!(context)
    end
  end
end
