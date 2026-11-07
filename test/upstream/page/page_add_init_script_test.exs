defmodule PlaywrightEx.Page.PageAddInitScriptTest do
  @upstream "tests/page/page-add-init-script.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  # Function scripts are JS source; without an `arg` a string is the script itself
  # (`function() { window.injected = 123; }` becomes `window['injected'] = 123`).

  test "IS-001 should evaluate before anything else on the page", %{page: page, server: server} do
    Page.add_init_script!(page, "window['injected'] = 123;")
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123
  end

  test "IS-002 should work with a path", %{page: page, server: server, asset: asset} do
    Page.add_init_script!(page, %{path: asset.("injectedfile.js")})
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123
  end

  test "IS-003 should work with content @smoke", %{page: page, server: server} do
    Page.add_init_script!(page, %{content: ~s|window["injected"] = 123|})
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123
  end

  test "IS-004 should throw without path and content", %{page: page} do
    # @ts-expect-error foo is not a real option of addInitScript: the facade rejects it, so the
    # client's check runs on an empty script object.
    assert_raise ArgumentError, ~r/unknown field :foo/, fn -> Page.add_init_script(page, %{foo: "bar"}) end
    {:error, error} = Page.add_init_script(page, %{})
    assert error.message =~ "Either path or content property must be present"
  end

  test "IS-005 should work with trailing comments", %{page: page} do
    Page.add_init_script!(page, %{content: "// comment"})
    Page.add_init_script!(page, %{content: "window.secret = 42;"})
    Page.goto!(page, "data:text/html,<html></html>")
    assert Page.evaluate!(page, "secret") == 42
  end

  test "IS-006 should support multiple scripts", %{page: page, server: server} do
    Page.add_init_script!(page, "window['script1'] = 1;")
    Page.add_init_script!(page, "window['script2'] = 2;")
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['script1']") == 1
    assert Page.evaluate!(page, "() => window['script2']") == 2
  end

  test "IS-007 should work with CSP", %{page: page, server: server} do
    TestServer.set_csp(server, "/empty.html", "script-src " <> server.prefix)
    Page.add_init_script!(page, "window['injected'] = 123;")
    Page.goto!(page, server.prefix <> "/empty.html")
    assert Page.evaluate!(page, "() => window['injected']") == 123

    # Make sure CSP works.
    Page.add_script_tag(page, content: "window.e = 10;")
    assert Page.evaluate!(page, "() => window['e']") == nil
  end

  test "IS-008 should work after a cross origin navigation", %{page: page, server: server} do
    Page.goto!(page, server.cross_process_prefix)
    Page.add_init_script!(page, "window['injected'] = 123;")
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123
  end

  test "IS-009 should remove init script after dispose", %{page: page, server: server} do
    disposable = Page.add_init_script!(page, "window['injected'] = 123;")
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123

    Disposable.dispose!(disposable)
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == nil
  end

  test "IS-010 should remove one of multiple init scripts after dispose", %{page: page, server: server} do
    disposable1 = Page.add_init_script!(page, "window['script1'] = 1;")
    Page.add_init_script!(page, "window['script2'] = 2;")
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['script1']") == 1
    assert Page.evaluate!(page, "() => window['script2']") == 2

    Disposable.dispose!(disposable1)
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['script1']") == nil
    assert Page.evaluate!(page, "() => window['script2']") == 2
  end

  test "IS-011 init script should run only once in iframe", %{page: page, server: server, browser_name: browser_name} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/26992' });
    test = self()

    Page.on(page, :console, fn event ->
      if String.starts_with?(ConsoleMessage.text(event), "init script:"),
        do: send(test, {:message, ConsoleMessage.text(event)})
    end)

    Page.add_init_script!(page, "console.log('init script:', location.pathname || 'no url yet')")
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    # isBidi: false (no BiDi channels here)
    assert_receive {:message, message1}, 5000
    assert_receive {:message, message2}, 5000
    refute_received {:message, _}

    assert [message1, message2] == [
             "init script: /frames/one-frame.html",
             "init script: " <> if(browser_name == "firefox", do: "no url yet", else: "/frames/frame.html")
           ]
  end
end
