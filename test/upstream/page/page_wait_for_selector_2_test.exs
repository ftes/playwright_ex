defmodule PlaywrightEx.Page.PageWaitForSelector2Test do
  @upstream "tests/page/page-wait-for-selector-2.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TimeoutError
  alias PlaywrightEx.Utils

  @moduletag :page

  @add_element "tag => document.body.appendChild(document.createElement(tag))"

  test "should survive cross-process navigation", %{page: page, server: server} do
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, ".box") end)
    Page.goto!(page, server.empty_page)
    assert Task.yield(wait_for_selector, 0) == nil
    Page.reload!(page)
    assert Task.yield(wait_for_selector, 0) == nil
    Page.goto!(page, server.cross_process_prefix <> "/grid.html")
    assert Task.await(wait_for_selector, :infinity)
  end

  test "should wait for visible", %{page: page} do
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, "div") end)
    Page.set_content!(page, "<div style='display: none; visibility: hidden;'>1</div>")
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').style.removeProperty('display')")
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').style.removeProperty('visibility')")
    assert Task.await(wait_for_selector, :infinity)
  end

  test "should not consider visible when zero-sized", %{page: page} do
    Page.set_content!(page, "<div style='width: 0; height: 0;'>1</div>")
    {:error, error} = Page.wait_for_selector(page, "div", timeout: 1000)
    assert Exception.message(error) =~ "page.waitForSelector: Timeout 1000ms exceeded"
    Page.evaluate!(page, "() => document.querySelector('div').style.width = '10px'")
    {:error, error} = Page.wait_for_selector(page, "div", timeout: 1000)
    assert Exception.message(error) =~ "page.waitForSelector: Timeout 1000ms exceeded"
    Page.evaluate!(page, "() => document.querySelector('div').style.height = '10px'")
    assert Page.wait_for_selector!(page, "div", timeout: 1000)
  end

  test "should wait for visible recursively", %{page: page} do
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, "div#inner") end)
    Page.set_content!(page, ~s(<div style='display: none; visibility: hidden;'><div id="inner">hi</div></div>))
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').style.removeProperty('display')")
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').style.removeProperty('visibility')")
    assert Task.await(wait_for_selector, :infinity)
  end

  test "should consider outside of viewport visible", %{page: page} do
    Page.set_content!(page, """
    <style>
      .cover {
        position: fixed;
        left: 0;
        top: 0;
        width: 100px;
        height: 100px;
        background-color: red;
        transform: translateX(-200px);
      }
    </style>
    <div class="cover">cover</div>
    """)

    cover = Page.locator(page, ".cover")
    Locator.wait_for!(cover, state: :visible)
    Expect.to_be_visible!(cover)
  end

  test "hidden should wait for hidden", %{page: page} do
    Page.set_content!(page, "<div style='display: block;'>content</div>")
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, "div", state: :hidden) end)
    # do a round trip
    Page.wait_for_selector!(page, "div")
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').style.setProperty('visibility', 'hidden')")
    Task.await(wait_for_selector, :infinity)
  end

  test "hidden should wait for display: none", %{page: page} do
    Page.set_content!(page, "<div style='display: block;'>content</div>")
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, "div", state: :hidden) end)
    # do a round trip
    Page.wait_for_selector!(page, "div")
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').style.setProperty('display', 'none')")
    Task.await(wait_for_selector, :infinity)
  end

  test "hidden should wait for removal", %{page: page} do
    Page.set_content!(page, "<div>content</div>")
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, "div", state: :hidden) end)
    # do a round trip
    Page.wait_for_selector!(page, "div")
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').remove()")
    Task.await(wait_for_selector, :infinity)
  end

  test "should return null if waiting to hide non-existing element", %{page: page} do
    handle = Page.wait_for_selector!(page, "non-existing", state: :hidden)
    assert handle == nil
  end

  test "should respect timeout", %{page: page} do
    {:error, error} = Page.wait_for_selector(page, "div", timeout: 3000, state: :attached)
    assert error
    assert Exception.message(error) =~ "page.waitForSelector: Timeout 3000ms exceeded"
    assert Exception.message(error) =~ "waiting for locator('div')"
    assert %TimeoutError{} = error
  end

  test "should have an error message specifically for awaiting an element to be hidden", %{page: page} do
    Page.set_content!(page, "<div>content</div>")
    {:error, error} = Page.wait_for_selector(page, "div", state: :hidden, timeout: 1000)
    assert error
    assert Exception.message(error) =~ "page.waitForSelector: Timeout 1000ms exceeded"
    assert Exception.message(error) =~ "waiting for locator('div') to be hidden"
  end

  test "should respond to node attribute mutation", %{page: page} do
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, ".zombo", state: :attached) end)
    Page.set_content!(page, "<div class='notZombo'></div>")
    assert Task.yield(wait_for_selector, 0) == nil
    Page.evaluate!(page, "() => document.querySelector('div').className = 'zombo'")
    assert Task.await(wait_for_selector, :infinity)
  end

  test "should return the element handle", %{page: page} do
    wait_for_selector = Task.async(fn -> Page.wait_for_selector!(page, ".zombo") end)
    Page.set_content!(page, "<div class='zombo'>anything</div>")
    assert Page.evaluate!(page, "x => x.textContent", Task.await(wait_for_selector, :infinity)) == "anything"
  end

  # `error.stack` is the stack trace of the raised error (the bang form; `{:error, e}` has none).
  # 'wait-for-selector' is this file's name: here its path, as the library's `wait_for_selector`
  # frames would match the name alone.
  test "should have correct stack trace for timeout", %{page: page} do
    {error, stacktrace} =
      try do
        Page.wait_for_selector!(page, ".zombo", timeout: 10)
        {nil, nil}
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert Exception.format(:error, error, stacktrace) =~ Path.relative_to_cwd(__ENV__.file)
  end

  test "should throw for unknown state option", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    {:error, error} = Page.wait_for_selector(page, "section", state: "foo")
    assert Exception.message(error) =~ "state: expected one of (attached|detached|visible|hidden)"
  end

  test "should throw for visibility option", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    # `visibility` is not an option of the facade: it rejects it before the driver does.
    assert_raise ArgumentError, ~r/unknown option :visibility/, fn ->
      Page.wait_for_selector(page, "section", visibility: :hidden)
    end
  end

  test "should throw for true state option", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    {:error, error} = Page.wait_for_selector(page, "section", state: true)
    assert Exception.message(error) =~ "state: expected one of (attached|detached|visible|hidden)"
  end

  test "should throw for false state option", %{page: page} do
    Page.set_content!(page, "<section>test</section>")
    {:error, error} = Page.wait_for_selector(page, "section", state: false)
    assert Exception.message(error) =~ "state: expected one of (attached|detached|visible|hidden)"
  end

  test "should support >> selector syntax", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    frame = Page.main_frame(page)
    watchdog = Task.async(fn -> Frame.wait_for_selector!(frame, "css=div >> css=span", state: :attached) end)
    Frame.evaluate!(frame, @add_element, "br")
    Frame.evaluate!(frame, @add_element, "div")
    Frame.evaluate!(frame, "() => document.querySelector('div').appendChild(document.createElement('span'))")
    e_handle = Task.await(watchdog, :infinity)
    tag_name = e_handle |> JSHandle.get_property!("tagName") |> JSHandle.json_value!()
    assert tag_name == "SPAN"
  end

  test "should wait for detached if already detached", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute">43543</section>))
    assert Page.wait_for_selector!(page, "css=div", state: :detached) == nil
  end

  test "should wait for detached", %{page: page} do
    Page.set_content!(page, ~s(<section id="testAttribute"><div>43543</div></section>))
    wait_for = Task.async(fn -> Page.wait_for_selector!(page, "css=div", state: :detached) end)
    assert Task.yield(wait_for, 0) == nil
    Page.wait_for_selector!(page, "css=section")
    assert Task.yield(wait_for, 0) == nil
    Page.eval_on_selector!(page, "div", "div => div.remove()")
    Task.await(wait_for, :infinity)
  end

  test "should support some fancy xpath", %{page: page} do
    Page.set_content!(page, "<p>red herring</p><p>hello  world  </p>")
    wait_for_x_path = Task.async(fn -> Page.wait_for_selector!(page, ~s|//p[normalize-space(.)="hello world"]|) end)
    assert Page.evaluate!(page, "x => x.textContent", Task.await(wait_for_x_path, :infinity)) == "hello  world  "
  end

  test "should respect timeout xpath", %{page: page} do
    {:error, error} = Page.wait_for_selector(page, "//div", state: :attached, timeout: 3000)
    assert error
    assert Exception.message(error) =~ "page.waitForSelector: Timeout 3000ms exceeded"
    assert Exception.message(error) =~ "waiting for locator('//div')"
    assert %TimeoutError{} = error
  end

  test "should run in specified frame xpath", %{page: page, server: server} do
    Utils.attach_frame(page, "frame1", server.empty_page)
    Utils.attach_frame(page, "frame2", server.empty_page)
    frame1 = Enum.at(Page.frames(page), 1)
    frame2 = Enum.at(Page.frames(page), 2)
    wait_for_x_path_promise = Task.async(fn -> Frame.wait_for_selector!(frame2, "//div", state: :attached) end)
    Frame.evaluate!(frame1, @add_element, "div")
    Frame.evaluate!(frame2, @add_element, "div")
    e_handle = Task.await(wait_for_x_path_promise, :infinity)
    assert ElementHandle.owner_frame!(e_handle) == frame2
  end

  test "should throw when frame is detached xpath", %{page: page, server: server} do
    Utils.attach_frame(page, "frame1", server.empty_page)
    frame = Enum.at(Page.frames(page), 1)
    wait_promise = Task.async(fn -> Frame.wait_for_selector(frame, ~s|//*[@class="box"]|) end)
    Utils.detach_frame(page, "frame1")
    {:error, wait_error} = Task.await(wait_promise, :infinity)
    assert wait_error
    assert Exception.message(wait_error) =~ "frame.waitForSelector: Frame was detached"
  end

  test "should return the element handle xpath", %{page: page} do
    wait_for_x_path = Task.async(fn -> Page.wait_for_selector!(page, ~s|//*[@class="zombo"]|) end)
    Page.set_content!(page, "<div class='zombo'>anything</div>")
    assert Page.evaluate!(page, "x => x.textContent", Task.await(wait_for_x_path, :infinity)) == "anything"
  end

  test "should allow you to select an element with single slash xpath", %{page: page} do
    Page.set_content!(page, "<div>some text</div>")
    wait_for_x_path = Task.async(fn -> Page.wait_for_selector!(page, "//html/body/div") end)
    assert Page.evaluate!(page, "x => x.textContent", Task.await(wait_for_x_path, :infinity)) == "some text"
  end

  test "should correctly handle hidden shadow host", %{page: page} do
    Page.set_content!(page, """
    <x-host hidden></x-host>
    <script>
      const host = document.querySelector('x-host');
      const root = host.attachShadow({ mode: 'open' });
      const style = document.createElement('style');
      style.textContent = ':host([hidden]) { display: none; }';
      root.appendChild(style);
      const child = document.createElement('div');
      child.textContent = 'Find me';
      root.appendChild(child);
    </script>
    """)

    assert Page.text_content!(page, "div") == "Find me"
    Page.wait_for_selector!(page, "div", state: :hidden)
  end

  test "should work when navigating before node adoption"

  test "should fail when navigating while on handle"

  test "should fail if element handle was detached while waiting", %{page: page} do
    Page.set_content!(page, "<button>hello</button>")
    button = Page.query_selector!(page, "button")
    promise = Task.async(fn -> ElementHandle.wait_for_selector(button, "something") end)
    Page.wait_for_timeout!(page, 100)
    Page.evaluate!(page, "() => document.body.innerText = ''")
    {:error, error} = Task.await(promise, :infinity)
    assert Exception.message(error) =~ "Element is not attached to the DOM"
  end

  test "should succeed if element handle was detached while waiting for hidden", %{page: page} do
    Page.set_content!(page, "<button>hello</button>")
    button = Page.query_selector!(page, "button")
    promise = Task.async(fn -> ElementHandle.wait_for_selector!(button, "something", state: :hidden) end)
    Page.wait_for_timeout!(page, 1000)
    Page.evaluate!(page, "() => document.body.innerText = ''")
    Task.await(promise, :infinity)
  end

  test "should succeed if element handle was detached while waiting for detached", %{page: page} do
    Page.set_content!(page, "<button>hello</button>")
    button = Page.query_selector!(page, "button")
    promise = Task.async(fn -> ElementHandle.wait_for_selector!(button, "something", state: :detached) end)
    Page.wait_for_timeout!(page, 1000)
    Page.evaluate!(page, "() => document.body.innerText = ''")
    Task.await(promise, :infinity)
  end
end
