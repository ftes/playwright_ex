defmodule PlaywrightEx.Page.PageBasicTest do
  @upstream "tests/page/page-basic.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise

  @moduletag :page

  test "should fire load when expected", %{page: page} do
    load = Page.wait_for_event(page, :load)
    Page.goto!(page, "about:blank")
    Promise.await!(load)
  end

  test "async stacks should work"

  test "should provide access to the opener page", %{page: page} do
    popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open('about:blank')") end)
    opener = Page.opener!(popup)
    assert opener == page
  end

  test "should fire domcontentloaded when expected", %{page: page} do
    # deviation: subscribe-first (OTP runtime)
    dom_content_loaded = Page.wait_for_event(page, :dom_content_loaded)
    navigated_promise = Task.async(fn -> Page.goto!(page, "about:blank") end)
    Promise.await!(dom_content_loaded)
    Task.await(navigated_promise, :infinity)
  end

  test "should pass self as argument to domcontentloaded event", %{page: page} do
    test = self()
    Page.on(page, :dom_content_loaded, &send(test, {:event_arg, &1}))
    Page.goto!(page, "about:blank")
    assert_receive {:event_arg, event_arg}
    assert event_arg == page
  end

  test "should pass self as argument to load event", %{page: page} do
    test = self()
    Page.on(page, :load, &send(test, {:event_arg, &1}))
    Page.goto!(page, "about:blank")
    assert_receive {:event_arg, event_arg}
    assert event_arg == page
  end

  test "page.url should work", %{page: page, server: server} do
    assert Page.url(page) == "about:blank"
    Page.goto!(page, server.empty_page)
    assert Page.url(page) == server.empty_page
  end

  test "page.url should include hashes", %{page: page, server: server} do
    Page.goto!(page, server.empty_page <> "#hash")
    assert Page.url(page) == server.empty_page <> "#hash"

    Page.evaluate!(page, """
    () => {
      window.location.hash = 'dynamic';
    }
    """)

    assert Page.url(page) == server.empty_page <> "#dynamic"
  end

  test "page.title should return the page title", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/title.html")
    assert Page.title!(page) == "Woof-Woof"
  end

  test "page.title should not throw during navigation", %{page: page, server: server} do
    Page.set_content!(page, "<title>hello</title>")
    promise = Task.async(fn -> Page.goto!(page, server.prefix <> "/title.html") end)
    title_or_error = Page.title!(page)
    Task.await(promise, :infinity)
    assert is_binary(title_or_error)
    assert title_or_error =~ ~r/^(hello|Loading http.*title.html||Woof-Woof)$/
    Expect.to_have_title!(page, "Woof-Woof")
  end

  test "page.close should work with window.close", %{page: page} do
    new_page_promise = Page.wait_for_event(page, :popup)
    Page.evaluate!(page, "() => window['newPage'] = window.open('about:blank')")
    new_page = Promise.await!(new_page_promise)
    test = self()
    Page.on(new_page, :close, fn _ -> send(test, :closed) end)
    Page.evaluate!(page, "() => window['newPage'].close()")
    assert_receive :closed
  end

  test "page.frame should respect name", %{page: page} do
    Page.set_content!(page, "<iframe name=target></iframe>")
    assert Page.frame(page, %{name: "bogus"}) == nil
    frame = Page.frame(page, %{name: "target"})
    assert frame
    assert frame == hd(Frame.child_frames(Page.main_frame(page)))
  end

  test "page.frame should respect url", %{page: page, server: server} do
    Page.set_content!(page, ~s(<iframe src="#{server.empty_page}"></iframe>))
    assert Page.frame(page, %{url: ~r/bogus/}) == nil
    assert Frame.url(Page.frame(page, %{url: ~r/empty/})) == server.empty_page
  end

  test "should have sane user agent", %{page: page, browser_name: browser_name} do
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

  test "page.press should work", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.press!(page, "textarea", "a")
    assert Page.evaluate!(page, "() => document.querySelector('textarea').value") == "a"
  end

  test "page.press should work for Enter", %{page: page} do
    Page.set_content!(page, ~s|<input onkeypress="console.log('press')"></input>|)
    test = self()
    Page.on(page, :console, &send(test, {:message, &1}))
    Page.press!(page, "input", "Enter")
    assert_receive {:message, message}
    assert ConsoleMessage.text(message) == "press"
  end

  test "frame.press should work", %{page: page, server: server} do
    Page.set_content!(page, ~s(<iframe name=inner src="#{server.prefix}/input/textarea.html"></iframe>))
    frame = Page.frame(page, "inner")
    Frame.press!(frame, "textarea", "a")
    assert Frame.evaluate!(frame, "() => document.querySelector('textarea').value") == "a"
  end

  test "has navigator.webdriver set to true", %{page: page} do
    assert Page.evaluate!(page, "() => navigator.webdriver") == true
  end

  test "should iterate over page properties"
end
