defmodule PlaywrightEx.Page.PageEventConsoleTest do
  @upstream "tests/page/page-event-console.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  # Collects events sent by listeners: `const messages = []; page.on(..., m => messages.push(...))`.
  defp received(acc \\ []) do
    receive do
      {:event, event} -> received([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @tag skip: "not ported: waitForEvent, JSHandle.jsonValue"
  test "should work @smoke"

  test "should emit same log twice", %{page: page} do
    test = self()
    Page.on(page, :console, fn m -> send(test, {:event, ConsoleMessage.text(m)}) end)

    Page.evaluate!(page, """
    () => {
      for (let i = 0; i < 2; ++i)
        console.log('hello');
    }
    """)

    assert received() == ["hello", "hello"]
  end

  test "should use text() for inspection", %{page: page} do
    test = self()
    inspect = fn value -> send(test, {:event, inspect(value)}) end
    Page.on(page, :console, inspect)
    Page.evaluate!(page, "() => console.log('Hello world')")
    # Deviation: Inspect wraps text() as `#PlaywrightEx.ConsoleMessage<...>`, like Locator's.
    assert received() == ["#PlaywrightEx.ConsoleMessage<Hello world>"]
  end

  test "should work for different console API calls", %{page: page} do
    test = self()
    Page.on(page, :console, fn msg -> send(test, {:event, msg}) end)
    # All console events will be reported before `page.evaluate` is finished.
    Page.evaluate!(page, """
    () => {
      // A pair of time/timeEnd generates only one Console API call.
      console.time('calling console.time');
      console.timeEnd('calling console.time');
      console.trace('calling console.trace');
      console.dir('calling console.dir');
      console.warn('calling console.warn');
      console.error('calling console.error');
      console.info('calling console.info');
      console.debug('calling console.debug');
      console.log(Promise.resolve('should not wait until resolved!'));
    }
    """)

    # WebKit uses console.debug() to report binding calls, make sure they don't get reported.
    Page.expose_binding!(page, "foobar", fn _, value -> Page.evaluate!(page, "value => console.log(value)", value) end)
    Page.evaluate!(page, "() => window['foobar']('Using bindings')")

    messages = received()

    assert Enum.map(messages, &ConsoleMessage.type/1) == [
             "timeEnd",
             "trace",
             "dir",
             "warning",
             "error",
             "info",
             "debug",
             "log",
             "log"
           ]

    assert ConsoleMessage.text(hd(messages)) =~ "calling console.time"

    assert Enum.map(tl(messages), &ConsoleMessage.text/1) == [
             "calling console.trace",
             "calling console.dir",
             "calling console.warn",
             "calling console.error",
             "calling console.info",
             "calling console.debug",
             "Promise",
             "Using bindings"
           ]
  end

  test "should format the message correctly with time/timeLog/timeEnd", %{page: page, browser_name: browser_name} do
    test = self()
    Page.on(page, :console, fn msg -> send(test, {:event, msg}) end)

    Page.evaluate!(page, """
    async () => {
      console.time('foo time');
      await new Promise(x => window.builtins.setTimeout(x, 100));
      console.timeLog('foo time');
      await new Promise(x => window.builtins.setTimeout(x, 100));
      console.timeEnd('foo time');
    }
    """)

    messages = received()
    assert length(messages) == 2

    case browser_name do
      "webkit" -> assert ConsoleMessage.type(Enum.at(messages, 0)) == "timeEnd"
      "chromium" -> assert ConsoleMessage.type(Enum.at(messages, 0)) == "log"
      "firefox" -> assert ConsoleMessage.type(Enum.at(messages, 0)) == "timeLog"
    end

    assert ConsoleMessage.type(Enum.at(messages, 1)) == "timeEnd"

    # WebKit has no space before the unit: https://bugs.webkit.org/show_bug.cgi?id=233556
    # Firefox/Bidi has no fractional part.
    assert ConsoleMessage.text(Enum.at(messages, 0)) =~ ~r/foo time: \d+(.\d+)? ?ms/
    assert ConsoleMessage.text(Enum.at(messages, 1)) =~ ~r/foo time: \d+(.\d+)? ?ms/
  end

  @tag skip: "not ported: waitForEvent"
  test "should not fail for window object"

  @tag skip: "not ported: waitForEvent"
  test "should not fail for object that can't be coerced to a primitive"

  @tag skip: "not ported: waitForEvent"
  test "should trigger correct Log"

  @tag skip: "not ported: waitForEvent"
  test "should have location for console API calls"

  @tag skip: "not ported: waitForEvent"
  test "should not throw when there are console messages in detached iframes"

  test "should use object previews for arrays and objects", %{page: page, browser_name: browser_name} do
    test = self()
    Page.on(page, :console, fn message -> send(test, {:event, ConsoleMessage.text(message)}) end)
    Page.evaluate!(page, "() => console.log([1, 2, 3], { a: 1 }, window)")
    text = List.last(received())

    if browser_name != "firefox",
      do: assert(text == "[1, 2, 3] {a: 1} Window"),
      else: assert(text == "Array JSHandle@object JSHandle@object")
  end

  test "should use object previews for errors", %{page: page, browser_name: browser_name} do
    test = self()
    Page.on(page, :console, fn message -> send(test, {:event, ConsoleMessage.text(message)}) end)
    Page.evaluate!(page, "() => console.log(new Error('Exception'))")
    text = List.last(received())

    case browser_name do
      "firefox" -> assert text == "Error"
      "chromium" -> assert text =~ ".evaluate"
      "webkit" -> assert text == "Error: Exception"
    end
  end

  @tag skip: "not ported: expect.poll"
  test "do not update console count on unhandled rejections"

  @tag skip: "not ported: waitForEvent"
  test "should have timestamp"

  test "should have increasing timestamps", %{page: page} do
    test = self()
    Page.on(page, :console, fn msg -> send(test, {:event, msg}) end)

    Page.evaluate!(page, """
    () => {
      console.log('first');
      console.log('second');
      console.log('third');
    }
    """)

    messages = received()
    assert length(messages) == 3

    for [previous, message] <- Enum.chunk_every(messages, 2, 1, :discard),
        do: assert(ConsoleMessage.timestamp(message) >= ConsoleMessage.timestamp(previous))
  end

  test "should have timestamp in consoleMessages", %{page: page} do
    # Generous slack to absorb host wall-clock resolution (e.g. ~15.6ms on Windows)
    # vs sub-millisecond browser timestamps.
    before = System.system_time(:millisecond) - 100
    Page.evaluate!(page, "() => console.log('stored message')")
    after_ = System.system_time(:millisecond) + 100
    messages = Page.console_messages!(page)
    assert messages != []
    last = List.last(messages)
    assert ConsoleMessage.text(last) == "stored message"
    assert ConsoleMessage.timestamp(last) >= before
    assert ConsoleMessage.timestamp(last) <= after_
  end

  test "consoleMessages should work", %{page: page} do
    Page.evaluate!(page, """
    () => {
      for (let i = 0; i < 301; i++)
        console.log('message' + i);
    }
    """)

    messages = Page.console_messages!(page)

    objects =
      Enum.map(
        messages,
        &%{text: ConsoleMessage.text(&1), type: ConsoleMessage.type(&1), page: ConsoleMessage.page(&1)}
      )

    expected = for i <- 201..300, do: %{text: "message#{i}", type: "log", page: page}

    assert length(objects) >= 100, "should be at least 100 messages"
    assert Enum.take(objects, -length(expected)) == expected, "should return last messages"
  end

  test "clearConsoleMessages should work", %{page: page} do
    Page.evaluate!(page, """
    () => {
      console.log('message1');
      console.log('message2');
    }
    """)

    messages = Page.console_messages!(page)
    assert "message1" in Enum.map(messages, &ConsoleMessage.text/1)
    assert "message2" in Enum.map(messages, &ConsoleMessage.text/1)

    Page.clear_console_messages!(page)

    messages = Page.console_messages!(page)
    assert messages == []

    Page.evaluate!(page, "() => console.log('message3')")
    messages = Page.console_messages!(page)
    assert length(messages) == 1
    assert ConsoleMessage.text(Enum.at(messages, 0)) == "message3"
  end

  test "consoleMessages since-navigation filter should work", %{page: page, server: server} do
    Page.evaluate!(page, "() => console.log('before navigation')")
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => console.log('after navigation')")

    all = Page.console_messages!(page, filter: :all)
    assert "before navigation" in Enum.map(all, &ConsoleMessage.text/1)
    assert "after navigation" in Enum.map(all, &ConsoleMessage.text/1)

    # since-navigation is the default
    since_nav = Page.console_messages!(page)
    refute "before navigation" in Enum.map(since_nav, &ConsoleMessage.text/1)
    assert "after navigation" in Enum.map(since_nav, &ConsoleMessage.text/1)
  end

  test "pageErrors since-navigation filter should work", %{page: page, server: server} do
    TestServer.set_content(server, "/page1", "<script>throw new Error('page1 error');</script>", "text/html")
    TestServer.set_content(server, "/page2", "<script>throw new Error('page2 error');</script>", "text/html")

    Page.goto!(page, server.prefix <> "/page1")
    Page.goto!(page, server.prefix <> "/page2")

    all = Page.page_errors!(page, filter: :all)
    assert "page1 error" in Enum.map(all, & &1.message)
    assert "page2 error" in Enum.map(all, & &1.message)

    # since-navigation is the default
    since_nav = Page.page_errors!(page)
    refute "page1 error" in Enum.map(since_nav, & &1.message)
    assert "page2 error" in Enum.map(since_nav, & &1.message)
  end
end
