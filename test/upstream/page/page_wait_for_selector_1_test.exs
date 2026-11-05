defmodule PlaywrightEx.Page.PageWaitForSelector1Test do
  @upstream "tests/page/page-wait-for-selector-1.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.Utils

  @moduletag :page

  # A call without `await` is `Runtime.Promise.async/1`: it returns once the call is sent, so the
  # logs of the first poll are not lost to a late start (as with `Task.async`).

  @add_element "tag => document.body.appendChild(document.createElement(tag))"

  defp give_it_time_to_log(frame), do: Utils.rafraf(frame, 2)

  test "should throw on waitFor", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    # `waitFor` is not an option of the facade: it rejects it before the driver does.
    assert_raise ArgumentError, ~r/unknown option :wait_for/, fn ->
      Page.wait_for_selector(page, "*", wait_for: "attached")
    end
  end

  test "should tolerate waitFor=visible", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    # `waitFor` is not an option of the facade: it rejects it before the driver tolerates it.
    assert_raise ArgumentError, ~r/unknown option :wait_for/, fn ->
      Page.wait_for_selector(page, "*", wait_for: "visible")
    end
  end

  test "should immediately resolve promise if node exists", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Page.main_frame(page)
    Frame.wait_for_selector!(frame, "*")
    Frame.evaluate!(frame, @add_element, "div")
    Frame.wait_for_selector!(frame, "div", state: :attached)
  end

  test "elementHandle.waitForSelector should immediately resolve if node exists", %{page: page} do
    Page.set_content!(page, "<span>extra</span><div><span>target</span></div>")
    div = Page.query_selector!(page, "div")
    span = ElementHandle.wait_for_selector!(div, "span", state: :attached)
    assert JSHandle.evaluate!(span, "e => e.textContent") == "target"
  end

  test "elementHandle.waitForSelector should wait", %{page: page} do
    Page.set_content!(page, "<div></div>")
    div = Page.query_selector!(page, "div")
    promise = Task.async(fn -> ElementHandle.wait_for_selector!(div, "span", state: :attached) end)
    JSHandle.evaluate!(div, "div => div.innerHTML = '<span>target</span>'")
    span = Task.await(promise)
    assert JSHandle.evaluate!(span, "e => e.textContent") == "target"
  end

  test "elementHandle.waitForSelector should timeout", %{page: page} do
    Page.set_content!(page, "<div></div>")
    div = Page.query_selector!(page, "div")
    {:error, error} = ElementHandle.wait_for_selector(div, "span", timeout: 100)
    assert Exception.message(error) =~ "Timeout 100ms exceeded."
  end

  test "elementHandle.waitForSelector should throw on navigation", %{page: page, server: server} do
    Page.set_content!(page, "<div></div>")
    div = Page.query_selector!(page, "div")
    promise = Task.async(fn -> ElementHandle.wait_for_selector(div, "span") end)
    # Give it some time before navigating.
    for _ <- 1..10, do: Page.evaluate!(page, "() => 1")
    Page.goto!(page, server.empty_page)
    {:error, error} = Task.await(promise)
    assert Exception.message(error) =~ "waiting for locator('span') to be visible"
  end

  test "should work with removed MutationObserver", %{page: page} do
    Page.evaluate!(page, "() => delete window.MutationObserver")
    task = Task.async(fn -> Page.wait_for_selector!(page, ".zombo") end)
    Page.set_content!(page, "<div class='zombo'>anything</div>")
    handle = Task.await(task)
    assert Page.evaluate!(page, "x => x.textContent", handle) == "anything"
  end

  test "should resolve promise when node is added", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Page.main_frame(page)
    watchdog = Task.async(fn -> Frame.wait_for_selector!(frame, "div", state: :attached) end)
    Frame.evaluate!(frame, @add_element, "br")
    Frame.evaluate!(frame, @add_element, "div")
    e_handle = Task.await(watchdog)
    tag_name = e_handle |> JSHandle.get_property!("tagName") |> JSHandle.json_value!()
    assert tag_name == "DIV"
  end

  test "should report logs while waiting for visible", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Page.main_frame(page)
    watchdog = Runtime.Promise.async(fn -> Frame.wait_for_selector(frame, "div", timeout: 5000) end)

    Frame.evaluate!(frame, """
    () => {
      const div = document.createElement('div');
      div.className = 'foo bar';
      div.id = 'mydiv';
      div.setAttribute('style', 'display: none');
      div.setAttribute('foo', '123456789012345678901234567890123456789012345678901234567890');
      div.textContent = 'abcdefghijklmnopqrstuvwyxzabcdefghijklmnopqrstuvwyxzabcdefghijklmnopqrstuvwyxz';
      document.body.appendChild(div);
    }
    """)

    give_it_time_to_log(frame)

    Frame.evaluate!(frame, "() => document.querySelector('div').remove()")
    give_it_time_to_log(frame)

    Frame.evaluate!(frame, """
    () => {
      const div = document.createElement('div');
      div.className = 'another';
      div.style.display = 'none';
      document.body.appendChild(div);
    }
    """)

    give_it_time_to_log(frame)

    {:error, error} = Promise.await!(watchdog)
    message = Exception.message(error)
    assert message =~ "frame.waitForSelector: Timeout 5000ms exceeded."
    assert message =~ "waiting for locator('div') to be visible"

    assert message =~
             ~s(locator resolved to hidden <div id="mydiv" class="foo bar" foo="123456789012345678901234567890123456789012345678901234567890">abcdefghijklmnopqrstuvwyxzabcdefghijklmnopqrstuvw…</div>)

    assert message =~ ~s(locator resolved to hidden <div class="another"></div>)
  end

  test "should report logs while waiting for hidden", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Page.main_frame(page)

    Frame.evaluate!(frame, """
    () => {
      const div = document.createElement('div');
      div.className = 'foo bar';
      div.id = 'mydiv';
      div.textContent = 'hello';
      document.body.appendChild(div);
    }
    """)

    watchdog = Runtime.Promise.async(fn -> Frame.wait_for_selector(frame, "div", state: :hidden, timeout: 5000) end)
    give_it_time_to_log(frame)

    Frame.evaluate!(frame, """
    () => {
      document.querySelector('div').remove();
      const div = document.createElement('div');
      div.className = 'another';
      div.textContent = 'hello';
      document.body.appendChild(div);
    }
    """)

    give_it_time_to_log(frame)

    {:error, error} = Promise.await!(watchdog)
    message = Exception.message(error)
    assert message =~ "frame.waitForSelector: Timeout 5000ms exceeded."
    assert message =~ "waiting for locator('div') to be hidden"
    assert message =~ ~s(locator resolved to visible <div id="mydiv" class="foo bar">hello</div>)
    assert message =~ ~s(locator resolved to visible <div class="another">hello</div>)
  end

  test "should report logs when the selector resolves to multiple elements", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <button style="display: none; position: absolute; top: 0px; left: 0px; width: 100%;">Reset</button>
    <button>Reset</button>
    """)

    {:error, error} = Page.click(page, "text=Reset", timeout: 1000)

    assert Exception.message(error) =~
             "locator resolved to 2 elements. Proceeding with the first one: <button>Reset</button>"
  end

  test "should resolve promise when node is added in shadow dom", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    watchdog = Task.async(fn -> Page.wait_for_selector!(page, "span") end)

    Page.evaluate!(page, """
    () => {
      const div = document.createElement('div');
      div.attachShadow({ mode: 'open' });
      document.body.appendChild(div);
    }
    """)

    Page.wait_for_timeout!(page, 100)

    Page.evaluate!(page, """
    () => {
      const span = document.createElement('span');
      span.textContent = 'Hello from shadow';
      document.querySelector('div').shadowRoot.appendChild(span);
    }
    """)

    handle = Task.await(watchdog)
    assert JSHandle.evaluate!(handle, "e => e.textContent") == "Hello from shadow"
  end

  test "should work when node is added through innerHTML", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    watchdog = Task.async(fn -> Page.wait_for_selector!(page, "h3 div", state: :attached) end)
    Page.evaluate!(page, @add_element, "span")
    Page.evaluate!(page, "() => document.querySelector('span').innerHTML = '<h3><div></div></h3>'")
    Task.await(watchdog)
  end

  test "page.waitForSelector is shortcut for main frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Utils.attach_frame(page, "frame1", server.empty_page)
    other_frame = Enum.at(Page.frames(page), 1)
    watchdog = Task.async(fn -> Page.wait_for_selector!(page, "div", state: :attached) end)
    Frame.evaluate!(other_frame, @add_element, "div")
    Page.evaluate!(page, @add_element, "div")
    e_handle = Task.await(watchdog)
    assert ElementHandle.owner_frame!(e_handle) == Page.main_frame(page)
  end

  test "should run in specified frame", %{page: page, server: server} do
    Utils.attach_frame(page, "frame1", server.empty_page)
    Utils.attach_frame(page, "frame2", server.empty_page)
    frame1 = Enum.at(Page.frames(page), 1)
    frame2 = Enum.at(Page.frames(page), 2)
    wait_for_selector_promise = Task.async(fn -> Frame.wait_for_selector!(frame2, "div", state: :attached) end)
    Frame.evaluate!(frame1, @add_element, "div")
    Frame.evaluate!(frame2, @add_element, "div")
    e_handle = Task.await(wait_for_selector_promise)
    assert ElementHandle.owner_frame!(e_handle) == frame2
  end

  test "should throw when frame is detached", %{page: page, server: server} do
    Utils.attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    wait_promise = Task.async(fn -> Frame.wait_for_selector(frame, ".box") end)
    Utils.detach_frame(page, "frame1")
    {:error, wait_error} = Task.await(wait_promise)
    assert wait_error
    assert Exception.message(wait_error) =~ "frame.waitForSelector: Frame was detached"
  end
end
