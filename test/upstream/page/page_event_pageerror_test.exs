defmodule PlaywrightEx.Page.PageEventPageerrorTest do
  @upstream "tests/page/page-event-pageerror.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp throw_later(page, expression, arg \\ nil) do
    Page.expect_event!(page, :page_error, fn -> Page.evaluate!(page, expression, arg) end)
  end

  test "should fire", %{page: page, server: server, browser_name: browser_name} do
    url = server.prefix <> "/error.html"
    error = Page.expect_event!(page, :page_error, fn -> Page.goto!(page, url) end)
    assert error.name == "Error"
    assert error.message == "Fancy error!"

    case browser_name do
      "chromium" ->
        assert error.stack == """
               Error: Fancy error!
                   at c (myscript.js:14:11)
                   at b (myscript.js:10:5)
                   at a (myscript.js:6:5)
                   at myscript.js:3:1\
               """

      "webkit" ->
        assert error.stack == """
               Error: Fancy error!
                   at c (#{url}:14:36)
                   at b (#{url}:10:6)
                   at a (#{url}:6:6)
                   at global code (#{url}:3:2)\
               """

      "firefox" ->
        assert error.stack == """
               Error: Fancy error!
                   at c (myscript.js:14:11)
                   at b (myscript.js:10:5)
                   at a (myscript.js:6:5)
                   at  (myscript.js:3:1)\
               """
    end
  end

  test "should not receive console message for pageError", %{page: page, server: server} do
    test = self()
    Page.on(page, :console, fn e -> send(test, {:console, e}) end)
    Page.expect_event!(page, :page_error, fn -> Page.goto!(page, server.prefix <> "/error.html") end)
    # `messages.length == 1`
    assert_received {:console, _}
    refute_received {:console, _}
  end

  test "should contain sourceURL", %{page: page, server: server, browser_name: browser_name} do
    # it.fail(browserName === 'webkit');
    expected_failure(browser_name == "webkit", fn ->
      error = Page.expect_event!(page, :page_error, fn -> Page.goto!(page, server.prefix <> "/error.html") end)
      assert error.stack =~ "myscript.js"
    end)
  end

  test "should contain the Error.name property", %{page: page} do
    error =
      throw_later(page, """
      () => {
        window.builtins.setTimeout(() => {
          const error = new Error('my-message');
          error.name = 'my-name';
          throw error;
        }, 0);
      }
      """)

    assert error.name == "my-name"
    assert error.message == "my-message"
  end

  test "should support an empty Error.name property", %{page: page} do
    error =
      throw_later(page, """
      () => {
        window.builtins.setTimeout(() => {
          const error = new Error('my-message');
          error.name = '';
          throw error;
        }, 0);
      }
      """)

    assert error.name == ""
    assert error.message == "my-message"
  end

  test "should handle odd values", %{page: page} do
    cases = [
      [:null, "null"],
      [nil, "undefined"],
      [0, "0"],
      ["", ""]
    ]

    for [value, message] <- cases do
      error = throw_later(page, "value => { window.builtins.setTimeout(() => { throw value; }, 0); }", value)
      assert error.message == message
    end
  end

  test "should handle object", %{page: page, browser_name: browser_name} do
    error = throw_later(page, "() => { window.builtins.setTimeout(() => { throw {}; }, 0); }")
    assert error.message == if(browser_name == "chromium", do: "Object", else: "[object Object]")
  end

  test "should handle window", %{page: page, browser_name: browser_name} do
    error = throw_later(page, "() => { window.builtins.setTimeout(() => { throw window; }, 0); }")
    assert error.message == if(browser_name == "chromium", do: "Window", else: "[object Window]")
  end

  test "should remove a listener of a non-existing event handler", %{page: page} do
    Page.remove_listener(page, :page_error, fn _ -> nil end)
  end

  test "should emit error from unhandled rejects", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/14165' }
    error =
      Page.expect_event!(page, :page_error, fn ->
        Page.set_content!(page, """
            <script>
              Promise.reject(new Error('sad :('));
            </script>
        """)
      end)

    assert error.message =~ "sad :("
  end

  test "pageErrors should work", %{page: page} do
    Page.evaluate!(page, """
    async () => {
      for (let i = 0; i < 301; i++)
        window.builtins.setTimeout(() => { throw new Error('error' + i); }, 0);
      await new Promise(f => window.builtins.setTimeout(f, 2000));
    }
    """)

    errors = Page.page_errors!(page)
    messages = Enum.map(errors, & &1.message)

    expected = for i <- 201..300, do: "error#{i}"

    assert length(messages) >= 100, "should be at least 100 errors"
    assert Enum.take(messages, -length(expected)) == expected, "should return last errors"
  end

  test "clearPageErrors should work", %{page: page} do
    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => { throw new Error('error1'); }, 0);
      window.builtins.setTimeout(() => { throw new Error('error2'); }, 0);
    }
    """)

    Page.wait_for_timeout!(page, 1000)

    errors = Page.page_errors!(page)
    assert "error1" in Enum.map(errors, & &1.message)
    assert "error2" in Enum.map(errors, & &1.message)

    Page.clear_page_errors!(page)

    errors = Page.page_errors!(page)
    assert errors == []

    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => { throw new Error('error3'); }, 0);
    }
    """)

    Page.wait_for_timeout!(page, 1000)

    errors = Page.page_errors!(page)
    assert length(errors) == 1
    assert Enum.at(errors, 0).message =~ "error3"
  end

  test "should fire illegal character error", %{page: page, server: server, browser_name: browser_name} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/38388' }
    TestServer.set_route(server, "/error.html", fn conn ->
      Plug.Conn.send_resp(conn, 200, """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="UTF-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1.0" />
            <title>vite-project</title>
          </head>
          <body>
            <div id="app"></div>
            <script >
              let a=10；//   !!!note: ； not ;
            </script>
          </body>
        </html>
      """)
    end)

    url = server.prefix <> "/error.html"
    error = Page.expect_event!(page, :page_error, fn -> Page.goto!(page, url) end)

    cond do
      browser_name == "chromium" ->
        assert error.message =~ "Invalid or unexpected token"

      browser_name == "webkit" and match?({:win32, _}, :os.type()) ->
        assert error.message =~ "No identifiers allowed directly after numeric literal"

      browser_name == "webkit" ->
        assert error.message =~ "Invalid character"

      true ->
        assert error.message =~ "illegal character"
    end
  end
end
