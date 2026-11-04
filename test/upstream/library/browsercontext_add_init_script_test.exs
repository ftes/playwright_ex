defmodule PlaywrightEx.Library.BrowsercontextAddInitScriptTest do
  @upstream "tests/library/browsercontext-add-init-script.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Page

  # contextTest: a fresh context per test. Function scripts are JS source; without an `arg`
  # a string is the script itself (`() => window.temp = 123` becomes `window.temp = 123`).
  setup %{context_factory: context_factory} do
    %{context: context_factory.([])}
  end

  test "should work with browser context scripts @smoke", %{context: context, server: server} do
    BrowserContext.add_init_script!(context, "window['temp'] = 123")
    page = BrowserContext.new_page!(context)
    Page.add_init_script!(page, "window['injected'] = window['temp']")
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123
  end

  test "should work without navigation, after all bindings", %{context: context} do
    test = self()

    BrowserContext.expose_function!(context, "woof", fn arg ->
      send(test, {:callback, arg})
      nil
    end)

    BrowserContext.add_init_script!(context, """
    window['woof']('hey');
    window['temp'] = 123;
    """)

    page = BrowserContext.new_page!(context)

    assert Page.evaluate!(page, "() => window['temp']") == 123
    assert_receive {:callback, "hey"}, 5000
  end

  test "should work without navigation in popup", %{context: context} do
    BrowserContext.add_init_script!(context, "window['temp'] = 123")
    page = BrowserContext.new_page!(context)

    {:ok, popup} =
      Page.expect_popup(page, fn -> Page.evaluate!(page, "() => { window['win'] = window.open(); }") end)

    assert Page.evaluate!(popup, "() => window['temp']") == 123
  end

  test "should work with browser context scripts with a path", %{context: context, server: server, asset: asset} do
    BrowserContext.add_init_script!(context, %{path: asset.("injectedfile.js")})
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123
  end

  test "should work with browser context scripts for already created pages", %{context: context, server: server} do
    page = BrowserContext.new_page!(context)
    BrowserContext.add_init_script!(context, "window['temp'] = 123")
    Page.add_init_script!(page, "window['injected'] = window['temp']")
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['result']") == 123
  end

  test "should remove context init script after dispose", %{context: context, server: server} do
    disposable = BrowserContext.add_init_script!(context, "window['temp'] = 123")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['temp']") == 123

    Disposable.dispose!(disposable)
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['temp']") == nil
  end

  test "should remove context init script and keep working in new pages", %{context: context, server: server} do
    disposable = BrowserContext.add_init_script!(context, "window['temp'] = 123")
    Disposable.dispose!(disposable)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.prefix <> "/tamperable.html")
    assert Page.evaluate!(page, "() => window['temp']") == nil
  end

  test "should expose functions passed as arguments", %{context: context, server: server} do
    test = self()

    BrowserContext.add_init_script!(
      context,
      """
      async ({ cb }) => {
        await cb(location.href);
      }
      """,
      %{
        cb: fn href ->
          send(test, {:received, href})
          nil
        end
      },
      expose_functions: true
    )

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    # await expect.poll(() => received).toContain(server.EMPTY_PAGE);
    empty_page = server.empty_page
    assert_receive {:received, ^empty_page}, 5000
  end

  test "should expose functions that survive navigation", %{context: context, server: server} do
    test = self()

    BrowserContext.add_init_script!(
      context,
      """
      ({ cb }) => {
        window.cb = cb;
      }
      """,
      %{
        cb: fn n ->
          send(test, {:received, n})
          n * 2
        end
      },
      expose_functions: true
    )

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => window.cb(1)") == 2
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Page.evaluate!(page, "() => window.cb(2)") == 4
    assert_received {:received, 1}
    assert_received {:received, 2}
    refute_received {:received, _}
  end

  test "should expose functions in popups", %{context: context, server: server} do
    BrowserContext.add_init_script!(
      context,
      """
      ({ mul }) => {
        window.mul = mul;
      }
      """,
      %{mul: fn a, b -> a * b end},
      expose_functions: true
    )

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    {:ok, popup} =
      Page.expect_popup(page, fn -> Page.evaluate!(page, "() => { window.open('about:blank'); }") end)

    assert Page.evaluate!(popup, "() => window.mul(6, 7)") == 42
  end

  test "should remove exposed functions after dispose", %{context: context, server: server} do
    disposable =
      BrowserContext.add_init_script!(
        context,
        """
        ({ cb }) => {
          window.cb = cb;
        }
        """,
        %{cb: fn n -> n * 2 end},
        expose_functions: true
      )

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => window.cb(21)") == 42
    Disposable.dispose!(disposable)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => typeof window.cb") == "undefined"
  end

  test "init script should run only once in popup", %{context: context} do
    BrowserContext.add_init_script!(context, "window['callCount'] = (window['callCount'] || 0) + 1;")
    page = BrowserContext.new_page!(context)

    {:ok, popup} =
      Page.expect_popup(page, fn -> Page.evaluate!(page, "() => { window.open('about:blank'); }") end)

    assert Page.evaluate!(popup, "callCount") == 1
  end
end
