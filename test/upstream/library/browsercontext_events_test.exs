defmodule PlaywrightEx.Library.BrowsercontextEventsTest do
  @upstream "tests/library/browsercontext-events.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Download
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Utils
  alias PlaywrightEx.WebError

  @moduletag :page

  test "BC-032 console event should work @smoke", %{page: page} do
    message_promise = BrowserContext.wait_for_event(Page.context(page), :console)
    Page.evaluate!(page, "() => console.log('hello')")
    message = Promise.await!(message_promise)

    assert ConsoleMessage.text(message) == "hello"
    assert ConsoleMessage.page(message) == page
  end

  test "BC-033 console event should work with element handles", %{page: page} do
    Page.set_content!(page, "<body>hello</body>")

    message =
      BrowserContext.expect_event!(Page.context(page), :console, fn ->
        Page.evaluate!(page, "() => console.log(document.body)")
      end)

    body = hd(ConsoleMessage.args(message))
    assert JSHandle.evaluate!(body, "x => x.nodeName") == "BODY"
    ElementHandle.click!(JSHandle.as_element(body))
  end

  test "BC-034 console event should work in popup", %{page: page} do
    message_promise = BrowserContext.wait_for_event(Page.context(page), :console)
    popup_promise = Page.wait_for_event(page, :popup)

    Page.evaluate!(page, """
    () => {
      const win = window.open('');
      win.console.log('hello');
    }
    """)

    message = Promise.await!(message_promise)
    popup = Promise.await!(popup_promise)

    assert ConsoleMessage.text(message) == "hello"
    assert ConsoleMessage.page(message) == popup
  end

  @tag skip:
         if(@browser_name == "firefox",
           do: "upstream fixme: console message from javascript: url is not reported at all"
         )
  test "BC-035 console event should work in popup 2", %{page: page} do
    message_promise =
      BrowserContext.wait_for_event(Page.context(page), :console,
        predicate: fn msg -> ConsoleMessage.type(msg) == "log" end
      )

    popup_promise = BrowserContext.wait_for_event(Page.context(page), :page)

    Page.evaluate!(page, """
    async () => {
      const win = window.open('javascript:console.log("hello")');
      await new Promise(f => window.builtins.setTimeout(f, 0));
      win.close();
    }
    """)

    message = Promise.await!(message_promise)
    popup = Promise.await!(popup_promise)

    assert ConsoleMessage.text(message) == "hello"
    assert ConsoleMessage.page(message) == popup
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: console message is not reported at all")
  test "BC-036 console event should work in immediately closed popup", %{page: page} do
    message_promise = BrowserContext.wait_for_event(Page.context(page), :console)
    popup_promise = Page.wait_for_event(page, :popup)

    Page.evaluate!(page, """
    async () => {
      const win = window.open();
      win.console.log('hello');
      win.close();
    }
    """)

    message = Promise.await!(message_promise)
    popup = Promise.await!(popup_promise)

    assert ConsoleMessage.text(message) == "hello"
    assert ConsoleMessage.page(message) == popup
  end

  test "BC-037 dialog event should work @smoke", %{page: page} do
    dialog1_promise = BrowserContext.wait_for_event(Page.context(page), :dialog)
    dialog2_promise = Page.wait_for_event(page, :dialog)
    task = Runtime.Promise.async(fn -> Page.evaluate!(page, "() => prompt('hey?')") end)
    dialog1 = Promise.await!(dialog1_promise)
    dialog2 = Promise.await!(dialog2_promise)

    assert dialog1 == dialog2
    assert Dialog.message(dialog1) == "hey?"
    assert Dialog.page(dialog1) == page
    Dialog.accept!(dialog1, "hello")
    assert Runtime.Promise.await(task) == "hello"
  end

  test "BC-038 dialogclosed event should work", %{page: page} do
    dialog_promise = BrowserContext.wait_for_event(Page.context(page), :dialog)
    task = Runtime.Promise.async(fn -> Page.evaluate!(page, "() => prompt('hey?')") end)
    dialog = Promise.await!(dialog_promise)
    closed1_promise = BrowserContext.wait_for_event(Page.context(page), :dialog_closed)
    closed2_promise = Page.wait_for_event(page, :dialog_closed)
    Dialog.accept!(dialog, "hello")
    closed1 = Promise.await!(closed1_promise)
    closed2 = Promise.await!(closed2_promise)
    assert closed1 == dialog
    assert closed2 == dialog
    assert Runtime.Promise.await(task) == "hello"
  end

  test "BC-039 dialog event should work in popup", %{page: page} do
    dialog_promise = BrowserContext.wait_for_event(Page.context(page), :dialog)
    popup_promise = Page.wait_for_event(page, :popup)

    task =
      Runtime.Promise.async(fn ->
        Page.evaluate!(page, """
        () => {
          const win = window.open('');
          return win.prompt('hey?');
        }
        """)
      end)

    dialog = Promise.await!(dialog_promise)
    popup = Promise.await!(popup_promise)

    assert Dialog.message(dialog) == "hey?"
    assert Dialog.page(dialog) == popup
    Dialog.accept!(dialog, "hello")
    assert Runtime.Promise.await(task) == "hello"
  end

  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: dialog from javascript: url is not reported at all")
  test "BC-040 dialog event should work in popup 2", %{page: page} do
    dialog_promise = BrowserContext.wait_for_event(Page.context(page), :dialog)

    task =
      Runtime.Promise.async(fn ->
        Page.evaluate!(page, """
        async () => {
          window.open('javascript:prompt("hey?")');
        }
        """)
      end)

    dialog = Promise.await!(dialog_promise)

    assert Dialog.message(dialog) == "hey?"
    assert Dialog.page(dialog) == nil
    Dialog.accept!(dialog, "hello")
    Runtime.Promise.await(task)
  end

  test "BC-041 dialog event should work in immediately closed popup", %{page: page} do
    dialog_promise = BrowserContext.wait_for_event(Page.context(page), :dialog)
    popup_promise = Page.wait_for_event(page, :popup)

    task =
      Runtime.Promise.async(fn ->
        Page.evaluate!(page, """
        async () => {
          const win = window.open();
          const result = win.prompt('hey?');
          win.close();
          return result;
        }
        """)
      end)

    dialog = Promise.await!(dialog_promise)
    popup = Promise.await!(popup_promise)

    assert Dialog.message(dialog) == "hey?"
    assert Dialog.page(dialog) == popup
    Dialog.accept!(dialog, "hello")
    assert Runtime.Promise.await(task) == "hello"
  end

  test "BC-042 dialog event should work with inline script tag", %{page: page, server: server} do
    TestServer.set_route(server, "/popup.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<script>window.result = prompt('hey?')</script>")
    end)

    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<a href='popup.html' target=_blank>Click me</a>")

    dialog_promise = BrowserContext.wait_for_event(Page.context(page), :dialog)
    popup_promise = BrowserContext.wait_for_event(Page.context(page), :page)
    task = Runtime.Promise.async(fn -> Page.click!(page, "a") end)
    dialog = Promise.await!(dialog_promise)
    popup = Promise.await!(popup_promise)

    assert Dialog.message(dialog) == "hey?"
    assert Dialog.page(dialog) == popup
    Dialog.accept!(dialog, "hello")
    Runtime.Promise.await(task)
    Utils.poll(fn -> Page.evaluate!(popup, "window.result") end, &assert(&1 == "hello"))
  end

  test "BC-043 weberror event should work", %{page: page} do
    web_error =
      BrowserContext.expect_event!(Page.context(page), :web_error, fn ->
        Page.set_content!(page, "<script>throw new Error(\"boom\")</script>")
      end)

    assert WebError.page(web_error) == page
    assert WebError.error(web_error).stack =~ "boom"
  end

  test "BC-044 weberror event should include location", %{page: page, server: server} do
    TestServer.set_route(server, "/error.js", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/javascript")
      |> Plug.Conn.send_resp(200, """

            function foo() {
              throw new Error('boom');
            }
            foo();
      """)
    end)

    TestServer.set_route(server, "/error.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<script src=\"/error.js\"></script>")
    end)

    web_error =
      BrowserContext.expect_event!(Page.context(page), :web_error, fn ->
        Page.goto!(page, server.prefix <> "/error.html")
      end)

    location = WebError.location(web_error)
    assert location.url == "#{server.prefix}/error.js"
    assert location.line == 2
    # column is not consistent across browsers
    assert location.column > 0
  end

  test "BC-045 pageload event should work @smoke", %{page: page, server: server} do
    event_page =
      BrowserContext.expect_event!(Page.context(page), :page_load, fn -> Page.goto!(page, server.empty_page) end)

    assert event_page == page
  end

  test "BC-046 framenavigated event should work @smoke", %{page: page, server: server} do
    frame =
      BrowserContext.expect_event!(Page.context(page), :frame_navigated, fn -> Page.goto!(page, server.empty_page) end)

    assert frame == Page.main_frame(page)
    assert Frame.url(frame) == server.empty_page
  end

  test "BC-047 pageclose event should work @smoke", %{context: context} do
    page = BrowserContext.new_page!(context)
    closed = BrowserContext.expect_event!(context, :page_close, fn -> Page.close!(page) end)
    assert closed == page
  end

  test "BC-048 frameattached event should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    frame =
      BrowserContext.expect_event!(Page.context(page), :frame_attached, fn ->
        Page.evaluate!(page, """
        () => {
          const iframe = document.createElement('iframe');
          iframe.src = 'about:blank';
          document.body.appendChild(iframe);
        }
        """)
      end)

    assert Frame.parent_frame(frame) == Page.main_frame(page)
  end

  test "BC-049 framedetached event should work @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.id = 'x';
      iframe.src = 'about:blank';
      document.body.appendChild(iframe);
    }
    """)

    Page.wait_for_selector!(page, "iframe")

    frame =
      BrowserContext.expect_event!(Page.context(page), :frame_detached, fn ->
        Page.evaluate!(page, "() => document.getElementById('x').remove()")
      end)

    assert Frame.parent_frame(frame) == Page.main_frame(page)
  end

  test "BC-050 download event should work @smoke", %{page: page, server: server} do
    TestServer.set_route(server, "/download", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/octet-stream")
      |> Plug.Conn.put_resp_header("content-disposition", "attachment; filename=file.txt")
      |> Plug.Conn.send_resp(200, "Hello world")
    end)

    Page.set_content!(page, "<a href=\"#{server.prefix}/download\">download</a>")
    download = BrowserContext.expect_event!(Page.context(page), :download, fn -> Page.click!(page, "a") end)
    assert Download.suggested_filename(download) == "file.txt"
    assert Download.page(download) == page
  end
end
