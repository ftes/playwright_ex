defmodule PlaywrightEx.Page.PageAddInitScriptCallbackTest do
  @upstream "tests/page/page-add-init-script-callback.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page

  @moduletag :page

  # Callbacks report to the test process: `received.push(n)` is `send(test, {:received, n})`.

  test "IS-012 should drop functions without the exposeFunctions option", %{page: page, server: server} do
    Page.add_init_script!(
      page,
      """
      ({ cb }) => {
        window.cbType = typeof cb;
      }
      """,
      %{cb: fn -> nil end}
    )

    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => window.cbType") == "undefined"
  end

  test "IS-013 should throw when the script is not a function", %{page: page} do
    {:error, e} = Page.add_init_script(page, %{content: "window.foo = 1;"}, nil, expose_functions: true)
    assert e.message =~ "Passing functions requires the init script to be a function"
  end

  test "IS-014 should call a function passed as an argument", %{page: page, server: server} do
    test = self()

    Page.add_init_script!(
      page,
      """
      async ({ cb }) => {
        await cb(1);
        await cb(2);
      }
      """,
      %{
        cb: fn n ->
          send(test, {:received, n})
          nil
        end
      },
      expose_functions: true
    )

    Page.goto!(page, server.empty_page)
    # await expect.poll(() => received).toEqual([1, 2]);
    assert_receive {:received, n1}, 5000
    assert_receive {:received, n2}, 5000
    assert [n1, n2] == [1, 2]
    refute_received {:received, _}
  end

  test "IS-015 should accept a function as the whole argument", %{page: page, server: server} do
    Page.add_init_script!(
      page,
      """
      async cb => {
        window.result = await cb('a');
      }
      """,
      fn s -> s <> "b" end,
      expose_functions: true
    )

    Page.goto!(page, server.empty_page)
    Expect.poll!(fn -> Page.evaluate!(page, "() => window.result") end, &assert(&1 == "ab"))
  end

  test "IS-016 should pass arguments to the callback", %{page: page, server: server} do
    test = self()

    cb = fn a, b, c, d ->
      send(test, {:args, [a, b, c, d]})
      nil
    end

    Page.add_init_script!(page, "({ cb }) => cb(1, 'two', { three: 3 }, [4])", %{cb: cb}, expose_functions: true)

    Page.goto!(page, server.empty_page)
    assert_receive {:args, args}, 5000
    assert args == [1, "two", %{"three" => 3}, [4]]
  end

  test "IS-017 should return the callback result to the page", %{page: page, server: server} do
    Page.add_init_script!(
      page,
      """
      async ({ double }) => {
        window.result = await double(21);
      }
      """,
      %{double: fn n -> n * 2 end},
      expose_functions: true
    )

    Page.goto!(page, server.empty_page)
    Expect.poll!(fn -> Page.evaluate!(page, "() => window.result") end, &assert(&1 == 42))
  end

  test "IS-018 should propagate callback errors to the page", %{page: page, server: server} do
    Page.add_init_script!(
      page,
      """
      async ({ cb }) => {
        try {
          await cb();
          window.result = 'no error';
        } catch (e) {
          window.result = e.message;
        }
      }
      """,
      %{cb: fn -> raise "boom" end},
      expose_functions: true
    )

    Page.goto!(page, server.empty_page)
    Expect.poll!(fn -> Page.evaluate!(page, "() => window.result") end, &assert(&1 =~ "boom"))
  end

  test "IS-019 should support multiple callbacks", %{page: page, server: server} do
    Page.add_init_script!(
      page,
      """
      async ({ add, mul }) => {
        window.result = (await add(2, 3)) + (await mul(2, 3));
      }
      """,
      %{add: fn a, b -> a + b end, mul: fn a, b -> a * b end},
      expose_functions: true
    )

    Page.goto!(page, server.empty_page)
    Expect.poll!(fn -> Page.evaluate!(page, "() => window.result") end, &assert(&1 == 11))
  end

  test "IS-020 should survive a navigation and keep working", %{page: page, server: server} do
    test = self()

    Page.add_init_script!(
      page,
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

    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => window.cb(1)") == 2
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    assert Page.evaluate!(page, "() => window.cb(2)") == 4
    assert_received {:received, 1}
    assert_received {:received, 2}
    refute_received {:received, _}
  end

  test "IS-021 should work in a child frame", %{page: page, server: server} do
    test = self()

    Page.add_init_script!(
      page,
      """
      async ({ cb }) => {
        await cb(42);
      }
      """,
      %{
        cb: fn n ->
          send(test, {:received, n})
          nil
        end
      },
      expose_functions: true
    )

    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    # Once for the main frame document, once for the child frame document.
    assert_receive {:received, n1}, 5000
    assert_receive {:received, n2}, 5000
    assert [n1, n2] == [42, 42]
    refute_received {:received, _}
  end

  test "IS-022 should not register the callback on the global object", %{page: page, server: server} do
    Page.add_init_script!(
      page,
      """
      async ({ cb }) => {
        await cb();
        window.result = Object.getOwnPropertyNames(globalThis).filter(name => name.startsWith('__pw_fn_'));
      }
      """,
      %{cb: fn -> nil end},
      expose_functions: true
    )

    Page.goto!(page, server.empty_page)
    Expect.poll!(fn -> Page.evaluate!(page, "() => window.result") end, &assert(&1 == []))
  end

  test "IS-023 should remove exposed functions after dispose", %{page: page, server: server} do
    test = self()

    disposable =
      Page.add_init_script!(
        page,
        """
        ({ cb }) => {
          window.cb = cb;
        }
        """,
        %{
          cb: fn n ->
            send(test, {:received, n})
            nil
          end
        },
        expose_functions: true
      )

    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => window.cb(1)")
    Disposable.dispose!(disposable)
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => typeof window.cb") == "undefined"
    assert_received {:received, 1}
    refute_received {:received, _}
  end
end
