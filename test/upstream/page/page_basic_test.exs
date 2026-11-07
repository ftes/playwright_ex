defmodule PlaywrightEx.Page.PageBasicTest do
  @upstream "tests/page/page-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  @moduletag :page

  test "PA-001 should fire load when expected", %{page: page} do
    load = Page.wait_for_event(page, :load)
    Page.goto!(page, "about:blank")
    Promise.await!(load)
  end

  # `error.stack` is the stack trace of the raised error (the bang form; `{:error, e}` has none),
  # `__filename` this file.
  test "PA-002 async stacks should work", %{page: page, server: server} do
    # req.socket.end(): close the connection without a response.
    TestServer.set_route(server, "/empty.html", fn %Plug.Conn{adapter: {Bandit.Adapter, adapter}} ->
      ThousandIsland.Socket.close(adapter.transport.socket)
      Process.exit(self(), :kill)
    end)

    {error, stacktrace} =
      try do
        Page.goto!(page, server.empty_page)
        {nil, nil}
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert error != nil
    assert Exception.format(:error, error, stacktrace) =~ Path.relative_to_cwd(__ENV__.file)
  end

  test "PA-003 should provide access to the opener page", %{page: page} do
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open('about:blank')") end)
    opener = Page.opener!(popup)
    assert opener == page
  end

  test "PA-004 should fire domcontentloaded when expected", %{page: page} do
    # deviation: subscribe-first (OTP runtime)
    dom_content_loaded = Page.wait_for_event(page, :dom_content_loaded)
    navigated_promise = Runtime.Promise.async(fn -> Page.goto!(page, "about:blank") end)
    Promise.await!(dom_content_loaded)
    Runtime.Promise.await(navigated_promise)
  end

  test "PA-005 should pass self as argument to domcontentloaded event", %{page: page} do
    test = self()
    Page.on(page, :dom_content_loaded, &send(test, {:event_arg, &1}))
    Page.goto!(page, "about:blank")
    assert_receive {:event_arg, event_arg}
    assert event_arg == page
  end

  test "PA-006 should pass self as argument to load event", %{page: page} do
    test = self()
    Page.on(page, :load, &send(test, {:event_arg, &1}))
    Page.goto!(page, "about:blank")
    assert_receive {:event_arg, event_arg}
    assert event_arg == page
  end

  test "PA-007 page.url should work", %{page: page, server: server} do
    assert Page.url(page) == "about:blank"
    Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page
  end

  test "PA-008 page.url should include hashes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page <> "#hash")
    assert Page.url(page) == server.empty_page <> "#hash"

    Page.evaluate!(page, """
    () => {
      window.location.hash = 'dynamic';
    }
    """)

    assert Page.url(page) == server.empty_page <> "#dynamic"
  end

  test "PA-009 page.title should return the page title", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/title.html")
    assert Page.title!(page) == "Woof-Woof"
  end

  test "PA-010 page.title should not throw during navigation", %{page: page, server: server} do
    Page.set_content!(page, "<title>hello</title>")
    promise = Runtime.Promise.async(fn -> Page.goto!(page, server.prefix <> "/title.html") end)
    title_or_error = Page.title!(page)
    Runtime.Promise.await(promise)
    assert is_binary(title_or_error)
    assert title_or_error =~ ~r/^(hello|Loading http.*title.html||Woof-Woof)$/
    Expect.to_have_title!(page, "Woof-Woof")
  end

  test "PA-011 page.close should work with window.close", %{page: page} do
    new_page_promise = Page.wait_for_event(page, :popup)
    Page.evaluate!(page, "() => window['newPage'] = window.open('about:blank')")
    new_page = Promise.await!(new_page_promise)
    test = self()
    Page.on(new_page, :close, fn _ -> send(test, :closed) end)
    Page.evaluate!(page, "() => window['newPage'].close()")
    assert_receive :closed
  end

  test "PA-012 page.frame should respect name", %{page: page} do
    Page.set_content!(page, "<iframe name=target></iframe>")
    assert Page.frame(page, %{name: "bogus"}) == nil
    frame = Page.frame(page, %{name: "target"})
    assert frame
    assert frame == hd(Frame.child_frames(Page.main_frame(page)))
  end

  test "PA-013 page.frame should respect url", %{page: page, server: server} do
    Page.set_content!(page, ~s(<iframe src="#{server.empty_page}"></iframe>))
    assert Page.frame(page, %{url: ~r/bogus/}) == nil
    assert Frame.url(Page.frame(page, %{url: ~r/empty/})) == server.empty_page
  end

  test "PA-014 should have sane user agent", %{page: page, browser_name: browser_name} do
    user_agent = Page.evaluate!(page, "() => navigator.userAgent")
    parts = user_agent |> String.split(~r/[()]/) |> Enum.map(&String.trim/1)
    [part1, _part2, part3 | _] = parts
    part4 = Enum.at(parts, 3)
    part5 = Enum.at(parts, 4)
    # First part is always "Mozilla/5.0"
    assert part1 == "Mozilla/5.0"
    # Second part in parenthesis is platform - ignore it.

    # Third part for Firefox is the last one and encodes engine and browser versions.
    if browser_name == "firefox" do
      [engine, browser | _] = String.split(part3, " ")
      assert String.starts_with?(engine, "Gecko")
      assert String.starts_with?(browser, "Firefox")
      assert part4 == nil
      assert part5 == nil
    else
      # For both options.CHROMIUM and options.WEBKIT, third part is the AppleWebKit version.
      assert String.starts_with?(part3, "AppleWebKit/")
      assert part4 == "KHTML, like Gecko"
      # 5th part encodes real browser name and engine version.
      tokens = String.split(part5, " ")
      engine = hd(tokens)
      browser = Enum.find(tokens, &String.starts_with?(&1, "Safari/"))
      assert browser && String.starts_with?(browser, "Safari/")

      if browser_name == "chromium",
        do: assert(String.contains?(engine, "Chrome/")),
        else: assert(String.starts_with?(engine, "Version/"))
    end
  end

  test "PA-015 page.press should work", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.press!(page, "textarea", "a")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "a"
  end

  test "PA-016 page.press should work for Enter", %{page: page} do
    Page.set_content!(page, ~s|<input onkeypress="console.log('press')"></input>|)
    test = self()
    Page.on(page, :console, &send(test, {:message, &1}))
    Page.press!(page, "input", "Enter")
    assert_receive {:message, message}
    assert ConsoleMessage.text(message) == "press"
  end

  test "PA-017 frame.press should work", %{page: page, server: server} do
    Page.set_content!(page, ~s(<iframe name=inner src="#{server.prefix}/input/textarea.html"></iframe>))
    frame = Page.frame(page, "inner")
    Frame.press!(frame, "textarea", "a")
    assert Frame.evaluate!(frame, "() => document.querySelector('textarea').value") == "a"
  end

  test "PA-018 has navigator.webdriver set to true", %{page: page} do
    assert Page.evaluate!(page, "() => navigator.webdriver") == true
  end

  # for..in over the page: the fields of its struct, each object value asked for its iterator
  # (`Enumerable.impl_for/1`).
  test "PA-019 should iterate over page properties", %{page: page} do
    _props = for {_prop, value} <- Map.from_struct(page), is_map(value), do: Enumerable.impl_for(value)
  end
end
