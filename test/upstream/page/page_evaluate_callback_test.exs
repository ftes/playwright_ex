defmodule PlaywrightEx.Page.PageEvaluateCallbackTest do
  @upstream "tests/page/page-evaluate-callback.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  # Callbacks report to the test process: `received.push(n)` is `send(test, {:received, n})`.
  defp received(acc \\ []) do
    receive do
      {:received, value} -> received([value | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp push(test) do
    fn value ->
      send(test, {:received, value})
      nil
    end
  end

  test "should throw without the exposeFunctions option", %{page: page} do
    {:error, e} = Page.evaluate(page, "({ cb }) => cb()", %{cb: fn -> nil end})
    # Deviation: the function renders as an Elixir term, not `() => {}`.
    assert e.message =~ ~r/Attempting to serialize unexpected value at position "cb": #Function</
  end

  test "should call a function passed as an argument", %{page: page} do
    Page.evaluate!(
      page,
      """
      async ({ cb }) => {
        await cb(1);
        await cb(2);
      }
      """,
      %{cb: push(self())},
      expose_functions: true
    )

    assert received() == [1, 2]
  end

  test "should accept a function as the whole argument", %{page: page} do
    Page.evaluate!(
      page,
      """
      async cb => {
        await cb('a');
        await cb('b');
      }
      """,
      push(self()),
      expose_functions: true
    )

    assert received() == ["a", "b"]
  end

  test "should pass arguments to the callback", %{page: page} do
    test = self()

    Page.evaluate(
      page,
      "({ cb }) => cb(1, 'two', { three: 3 }, [4])",
      %{
        cb: fn a, b, c, d ->
          send(test, {:args, [a, b, c, d]})
          nil
        end
      },
      expose_functions: true
    )

    assert_receive {:args, args}, 5000
    assert args == [1, "two", %{"three" => 3}, [4]]
  end

  test "should return the callback result to the page", %{page: page} do
    doubled = Page.evaluate!(page, "async ({ cb }) => await cb(21)", %{cb: fn n -> n * 2 end}, expose_functions: true)
    assert doubled == 42
  end

  test "should support handle as a callback result", %{page: page} do
    result =
      Page.evaluate!(
        page,
        """
        async cb => {
          const value = await cb(42);
          return value + 17;
        }
        """,
        fn n -> Page.evaluate_handle!(page, "x => 2 * x", n) end,
        expose_functions: true
      )

    assert result == 101
  end

  test "should support nested handles in the callback result", %{page: page} do
    result =
      Page.evaluate!(
        page,
        """
        async cb => {
          const res = await cb(42);
          return res.mul[0] + res.mul[1] + res.add;
        }
        """,
        fn n ->
          double = Page.evaluate_handle!(page, "x => 2 * x", n)
          triple = Page.evaluate_handle!(page, "x => 3 * x", n)
          %{mul: [double, triple], add: 17}
        end,
        expose_functions: true
      )

    assert result == 227
  end

  test "should await an async callback result", %{page: page} do
    value =
      Page.evaluate!(
        page,
        "async ({ cb }) => await cb(20)",
        %{
          cb: fn n ->
            Process.sleep(10)
            n + 1
          end
        },
        expose_functions: true
      )

    assert value == 21
  end

  test "should propagate callback errors to the page", %{page: page} do
    message =
      Page.evaluate!(
        page,
        """
        async ({ cb }) => {
          try {
            await cb();
            return 'no error';
          } catch (e) {
            return e.message;
          }
        }
        """,
        %{cb: fn -> raise "boom" end},
        expose_functions: true
      )

    assert message =~ "boom"
  end

  test "should work with a fire-and-forget setTimeout callback", %{page: page} do
    test = self()

    Page.evaluate(
      page,
      "({ cb }) => { setTimeout(() => cb(5), 0); }",
      %{
        cb: fn n ->
          send(test, {:value, n})
          nil
        end
      },
      expose_functions: true
    )

    assert_receive {:value, 5}, 5000
  end

  test "should support multiple callbacks", %{page: page} do
    result =
      Page.evaluate!(
        page,
        """
        async ({ add, mul }) => {
          return (await add(2, 3)) + (await mul(2, 3));
        }
        """,
        %{add: fn a, b -> a + b end, mul: fn a, b -> a * b end},
        expose_functions: true
      )

    assert result == 11
  end

  test "should work with evaluateHandle", %{page: page} do
    handle =
      Page.evaluate_handle!(
        page,
        """
        async ({ cb }) => {
          await cb(7);
          return { done: true };
        }
        """,
        %{cb: push(self())},
        expose_functions: true
      )

    assert JSHandle.json_value!(handle) == %{"done" => true}
    assert received() == [7]
  end

  test "should work in a child frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Utils.attach_frame(page, "frame1", server.empty_page)
    Frame.evaluate!(frame, "async ({ cb }) => { await cb(42); }", %{cb: push(self())}, expose_functions: true)
    assert received() == [42]
  end

  test "should route callbacks back to the calling frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Utils.attach_frame(page, "frame1", server.empty_page)
    greet = fn where -> "hello #{where}" end

    [from_main, from_child] =
      Task.await_many(
        [
          Task.async(fn ->
            Page.evaluate!(page, "async ({ cb }) => await cb('main')", %{cb: greet}, expose_functions: true)
          end),
          Task.async(fn ->
            Frame.evaluate!(frame, "async ({ cb }) => await cb('child')", %{cb: greet}, expose_functions: true)
          end)
        ],
        :infinity
      )

    assert from_main == "hello main"
    assert from_child == "hello child"
  end

  test "should work with jsHandle.evaluate", %{page: page} do
    handle = Page.evaluate_handle!(page, "() => window")

    JSHandle.evaluate!(handle, "async (win, { cb }) => { await cb(99); }", %{cb: push(self())}, expose_functions: true)

    assert received() == [99]
  end

  test "should work with locator.evaluate", %{page: page} do
    Page.set_content!(page, "<div id=target>hello</div>")

    Locator.evaluate!(
      Page.locator(page, "#target"),
      "async (element, { cb }) => { await cb(element.id); }",
      %{cb: push(self())},
      expose_functions: true
    )

    assert received() == ["target"]
  end

  test "should return the callback result with locator.evaluate", %{page: page} do
    Page.set_content!(page, "<div id=target>7</div>")

    result =
      Locator.evaluate!(
        Page.locator(page, "#target"),
        """
        async (element, { double }) => {
          return await double(+element.textContent);
        }
        """,
        %{double: fn n -> n * 2 end},
        expose_functions: true
      )

    assert result == 14
  end

  test "should propagate callback errors with locator.evaluate", %{page: page} do
    Page.set_content!(page, "<div id=target></div>")

    message =
      Locator.evaluate!(
        Page.locator(page, "#target"),
        """
        async (element, { cb }) => {
          try {
            await cb();
            return 'no error';
          } catch (e) {
            return e.message;
          }
        }
        """,
        %{cb: fn -> raise "boom" end},
        expose_functions: true
      )

    assert message =~ "boom"
  end

  test "should work with locator.evaluateHandle", %{page: page} do
    Page.set_content!(page, "<div id=target>hello</div>")

    handle =
      Locator.evaluate_handle!(
        Page.locator(page, "#target"),
        """
        async (element, { cb }) => {
          await cb(element.id);
          return element;
        }
        """,
        %{cb: push(self())},
        expose_functions: true
      )

    assert received() == ["target"]
    assert JSHandle.evaluate!(handle, "element => element.id") == "target"
  end

  test "should work with locator.evaluate inside an iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Utils.attach_frame(page, "frame1", server.empty_page)
    Frame.evaluate!(frame, "() => { document.body.innerHTML = '<div id=target>in-frame</div>'; }")

    Page.frame_locator(page, "#frame1")
    |> PlaywrightEx.FrameLocator.locator("#target")
    |> Locator.evaluate!("async (element, { cb }) => { await cb(element.textContent); }", %{cb: push(self())},
      expose_functions: true
    )

    assert received() == ["in-frame"]
  end

  test "should survive a navigation and keep working", %{page: page, server: server} do
    Page.evaluate!(page, "async ({ cb }) => { await cb(1); }", %{cb: push(self())}, expose_functions: true)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "async ({ cb }) => { await cb(2); }", %{cb: push(self())}, expose_functions: true)
    assert received() == [1, 2]
  end

  test "should not register the callback on the global object", %{page: page} do
    result =
      Page.evaluate!(
        page,
        """
        async ({ cb }) => {
          await cb();
          return Object.getOwnPropertyNames(globalThis).filter(name => name.startsWith('__pw_fn_'));
        }
        """,
        %{cb: fn -> nil end},
        expose_functions: true
      )

    assert result == []
  end

  test "should scope the page-side callback to the execution context", %{page: page, server: server} do
    Page.evaluate!(page, "({ cb }) => { window.__cb = cb; }", %{cb: fn -> nil end}, expose_functions: true)
    assert Page.evaluate!(page, "() => typeof window.__cb") == "function"
    Page.goto!(page, server.empty_page)
    assert Page.evaluate!(page, "() => typeof window.__cb") == "undefined"
  end
end
