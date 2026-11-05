defmodule PlaywrightEx.Page.LocatorFrameTest do
  @upstream "tests/page/locator-frame.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Request
  alias PlaywrightEx.Route

  @moduletag :page

  defp route_iframe(page) do
    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill(route, body: ~s(<iframe src="iframe.html" name="frame1"></iframe>), content_type: "text/html")
    end)

    Page.route!(page, "**/iframe.html", fn route ->
      Route.fulfill(route,
        body: """
                <html>
                  <div>
                    <button data-testid="buttonId">Hello iframe</button>
                    <iframe src="iframe-2.html"></iframe>
                  </div>
                  <span>1</span>
                  <span>2</span>
                  <label for=target>Name</label><input id=target type=text placeholder=Placeholder title=Title alt=Alternative>
                </html>
        """,
        content_type: "text/html"
      )
    end)

    Page.route!(page, "**/iframe-2.html", fn route ->
      Route.fulfill(route, body: "<html><button>Hello nested iframe</button></html>", content_type: "text/html")
    end)
  end

  defp route_ambiguous(page) do
    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill(route,
        body: """
        <iframe src="iframe-1.html"></iframe>
                     <iframe src="iframe-2.html"></iframe>
                     <iframe src="iframe-3.html"></iframe>
        """,
        content_type: "text/html"
      )
    end)

    Page.route!(page, "**/iframe-*", fn route ->
      "/" <> path = URI.parse(Request.url(Route.request(route))).path

      Route.fulfill(route, body: "<html><button>Hello from #{path}</button></html>", content_type: "text/html")
    end)
  end

  test "should work for iframe @smoke", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = page |> Page.frame_locator("iframe") |> FrameLocator.locator("button")
    Locator.wait_for!(button)
    assert Locator.inner_text!(button) == "Hello iframe"
    Expect.to_have_text!(button, "Hello iframe")
    Locator.click!(button)
  end

  test "should work for nested iframe", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)

    button =
      page |> Page.frame_locator("iframe") |> FrameLocator.frame_locator("iframe") |> FrameLocator.locator("button")

    Locator.wait_for!(button)
    assert Locator.inner_text!(button) == "Hello nested iframe"
    Expect.to_have_text!(button, "Hello nested iframe")
    Locator.click!(button)
  end

  test "should work for $ and $$", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("button")
    Expect.to_have_text!(locator, "Hello iframe")
    spans = page |> Page.frame_locator("iframe") |> FrameLocator.locator("span")
    Expect.to_have_count!(spans, 2)
  end

  test "should wait for frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    {:error, error} =
      page
      |> Page.locator("body")
      |> Locator.frame_locator("iframe")
      |> FrameLocator.locator("span")
      |> Locator.click(timeout: 1000)

    assert error.message =~ "waiting for locator('body').locator('iframe').contentFrame()"
  end

  test "should wait for frame 2", %{page: page, server: server} do
    route_iframe(page)

    Task.start(fn ->
      Process.sleep(300)
      Page.goto(page, server.empty_page)
    end)

    page |> Page.frame_locator("iframe") |> FrameLocator.locator("button") |> Locator.click!()
  end

  test "should wait for frame to go", %{page: page, server: server} do
    # it.fixme(isAndroid);

    route_iframe(page)
    Page.goto!(page, server.empty_page)

    Task.start(fn ->
      Process.sleep(300)
      Page.eval_on_selector(page, "iframe", "e => e.remove()")
    end)

    Expect.to_be_hidden!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("button"))
  end

  test "should not wait for frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Expect.to_be_hidden!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("span"))
  end

  test "should not wait for frame 2", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Expect.not_to_be_visible!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("span"))
  end

  test "should not wait for frame 3", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Expect.to_have_count!(page |> Page.frame_locator("iframe") |> FrameLocator.locator("span"), 0)
  end

  test "should click in lazy iframe", %{page: page, server: server} do
    Page.route!(page, "**/iframe.html", fn route ->
      Route.fulfill(route, body: "<html><button>Hello iframe</button></html>", content_type: "text/html")
    end)

    # empty pge
    Page.goto!(page, server.empty_page)

    # add blank iframe
    Task.start(fn ->
      Process.sleep(500)

      Task.start(fn ->
        Page.evaluate(page, """
        () => {
          const iframe = document.createElement('iframe');
          document.body.appendChild(iframe);
        }
        """)
      end)

      # navigate iframe
      Process.sleep(500)
      Page.evaluate(page, "() => document.querySelector('iframe').src = 'iframe.html'")
    end)

    # Click in iframe
    button = page |> Page.frame_locator("iframe") |> FrameLocator.locator("button")

    [_, text, _] =
      Task.await_many(
        [
          Task.async(fn -> Locator.click!(button) end),
          Task.async(fn -> Locator.inner_text!(button) end),
          Task.async(fn -> Expect.to_have_text!(button, "Hello iframe") end)
        ],
        :infinity
      )

    assert text == "Hello iframe"
  end

  test "waitFor should survive frame reattach", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = page |> Page.frame_locator("iframe") |> FrameLocator.locator(~s|button:has-text("Hello nested iframe")|)
    promise = Task.async(fn -> Locator.wait_for!(button) end)
    Locator.evaluate!(Page.locator(page, "iframe"), "e => e.remove()")

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = 'iframe-2.html';
      document.body.appendChild(iframe);
    }
    """)

    Task.await(promise, :infinity)
  end

  test "click should survive frame reattach", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = page |> Page.frame_locator("iframe") |> FrameLocator.locator(~s|button:has-text("Hello nested iframe")|)
    promise = Task.async(fn -> Locator.click!(button) end)
    Locator.evaluate!(Page.locator(page, "iframe"), "e => e.remove()")

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = 'iframe-2.html';
      document.body.appendChild(iframe);
    }
    """)

    Task.await(promise, :infinity)
  end

  test "click should survive iframe navigation", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = page |> Page.frame_locator("iframe") |> FrameLocator.locator(~s|button:has-text("Hello nested iframe")|)
    promise = Task.async(fn -> Locator.click!(button) end)
    Task.start(fn -> Locator.evaluate(Page.locator(page, "iframe"), "e => e.src = 'iframe-2.html'") end)
    Task.await(promise, :infinity)
  end

  test "should non work for non-frame", %{page: page} do
    route_iframe(page)
    Page.set_content!(page, "<div></div>")
    button = page |> Page.frame_locator("div") |> FrameLocator.locator("button")
    {:error, error} = Locator.wait_for(button)
    assert error.message =~ "<div></div>"
    assert error.message =~ "<iframe> was expected"
  end

  test "locator.frameLocator should work for iframe", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = page |> Page.locator("body") |> Locator.frame_locator("iframe") |> FrameLocator.locator("button")
    Locator.wait_for!(button)
    assert Locator.inner_text!(button) == "Hello iframe"
    Expect.to_have_text!(button, "Hello iframe")
    Locator.click!(button)
  end

  test "locator.frameLocator should throw on ambiguity", %{page: page, server: server} do
    route_ambiguous(page)
    Page.goto!(page, server.empty_page)
    button = page |> Page.locator("body") |> Locator.frame_locator("iframe") |> FrameLocator.locator("button")
    {:error, error} = Locator.wait_for(button)

    assert error.message =~
             "Error: strict mode violation: locator('body').locator('iframe') resolved to 3 elements"
  end

  test "locator.frameLocator should not throw on first/last/nth", %{page: page, server: server} do
    route_ambiguous(page)
    Page.goto!(page, server.empty_page)

    button1 =
      page
      |> Page.locator("body")
      |> Locator.frame_locator("iframe")
      |> FrameLocator.first()
      |> FrameLocator.locator("button")

    Expect.to_have_text!(button1, "Hello from iframe-1.html")

    button2 =
      page
      |> Page.locator("body")
      |> Locator.frame_locator("iframe")
      |> FrameLocator.nth(1)
      |> FrameLocator.locator("button")

    Expect.to_have_text!(button2, "Hello from iframe-2.html")

    button3 =
      page
      |> Page.locator("body")
      |> Locator.frame_locator("iframe")
      |> FrameLocator.last()
      |> FrameLocator.locator("button")

    Expect.to_have_text!(button3, "Hello from iframe-3.html")
  end

  test "getBy coverage", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button1 = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_role(:button)
    button2 = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_text("Hello")
    button3 = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_test_id("buttonId")
    Expect.to_have_text!(button1, "Hello iframe")
    Expect.to_have_text!(button2, "Hello iframe")
    Expect.to_have_text!(button3, "Hello iframe")
    input1 = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_label("Name")
    Expect.to_have_value!(input1, "")
    input2 = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_placeholder("Placeholder")
    Expect.to_have_value!(input2, "")
    input3 = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_alt_text("Alternative")
    Expect.to_have_value!(input3, "")
    input4 = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_title("Title")
    Expect.to_have_value!(input4, "")
  end

  # https://github.com/microsoft/playwright/issues/21879
  test "wait for hidden should succeed when frame is not in dom", %{page: page} do
    Page.goto!(page, "about:blank")
    button = page |> Page.frame_locator("iframe1") |> FrameLocator.locator("button")
    assert Locator.is_hidden!(button)
    Locator.wait_for!(button, state: :hidden, timeout: 1000)
    Locator.wait_for!(button, state: :detached, timeout: 1000)
    {:error, error} = Locator.wait_for(button, state: :attached, timeout: 1000)
    assert error.message =~ "Timeout 1000ms exceeded"
  end

  # https://github.com/microsoft/playwright/issues/28082
  @tag skip: if(@browser_name == "firefox", do: "upstream fixme: firefox")
  test "should work with COEP/COOP/CORP isolated iframe", %{page: page, server: server} do
    # it.fixme(browserName === 'firefox');
    headers = %{
      "cross-origin-embedder-policy" => "require-corp",
      "cross-origin-opener-policy" => "same-origin",
      "cross-origin-resource-policy" => "cross-origin"
    }

    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill!(route,
        body:
          ~s(<iframe src="https://#{server.cross_process_prefix}/btn.html" allow="cross-origin-isolated; fullscreen" sandbox="allow-same-origin allow-scripts allow-popups" ></iframe>),
        content_type: "text/html",
        headers: headers
      )
    end)

    Page.route!(page, "**/btn.html", fn route ->
      Route.fulfill!(route,
        body: ~s(<button onclick="window.__clicked=true">Click target</button>),
        content_type: "text/html",
        headers: headers
      )
    end)

    Page.goto!(page, server.empty_page)
    page |> Page.frame_locator("iframe") |> FrameLocator.get_by_role(:button) |> Locator.click!()
    assert page |> Page.frames() |> Enum.at(1) |> Frame.evaluate!("() => window['__clicked']") == true
  end

  test "locator.contentFrame should work", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    locator = Page.locator(page, "iframe")
    frame_locator = Locator.content_frame(locator)
    button = FrameLocator.locator(frame_locator, "button")
    assert Locator.inner_text!(button) == "Hello iframe"
    Expect.to_have_text!(button, "Hello iframe")
    Locator.click!(button)
  end

  test "frameLocator.owner should work", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    frame_locator = Page.frame_locator(page, "iframe")
    locator = FrameLocator.owner(frame_locator)
    Expect.to_be_visible!(locator)
    assert Locator.get_attribute!(locator, "name") == "frame1"
  end

  # https://github.com/microsoft/playwright/issues/42719
  test "should treat elements inside hidden iframe as hidden", %{page: page} do
    Page.set_content!(page, """
      <iframe name="hidden" style="visibility: hidden" srcdoc="<button>Hidden</button>"></iframe>
      <div style="visibility: hidden">
        <iframe name="hidden-parent" srcdoc="<button>Hidden parent</button>"></iframe>
        <iframe name="visible-override" style="visibility: visible" srcdoc="<button>Visible override</button>"></iframe>
      </div>
      <iframe name="outer" style="visibility: hidden" srcdoc="<iframe name='inner' srcdoc='<button>Nested</button>'></iframe>"></iframe>
    """)

    for button <- [
          page |> Page.frame_locator("[name=hidden]") |> FrameLocator.locator("button"),
          page |> Page.frame_locator("[name=hidden-parent]") |> FrameLocator.locator("button"),
          page
          |> Page.frame_locator("[name=outer]")
          |> FrameLocator.frame_locator("[name=inner]")
          |> FrameLocator.locator("button")
        ] do
      Expect.to_be_attached!(button)
      assert Locator.is_visible!(button) == false
      assert Locator.is_hidden!(button) == true
      Expect.to_be_hidden!(button)
      Expect.not_to_be_visible!(button)
      Locator.wait_for!(button, state: :hidden)
    end

    button = page |> Page.frame_locator("[name=visible-override]") |> FrameLocator.locator("button")
    assert Locator.is_visible!(button) == true
    Expect.to_be_visible!(button)
    Locator.wait_for!(button, state: :visible)
  end

  # https://github.com/microsoft/playwright/issues/42719
  test "should wait for hidden iframe to become visible", %{page: page} do
    Page.set_content!(
      page,
      ~s|<iframe name="frame" style="visibility: hidden" srcdoc="<button onclick='window.__clicked = true'>Button</button>"></iframe>|
    )

    button = page |> Page.frame_locator("[name=frame]") |> FrameLocator.locator("button")
    Expect.to_be_hidden!(button)

    {:error, error} = Locator.click(button, timeout: 1000)
    assert error.message =~ "element is inside a hidden frame, retrying"
    assert Locator.evaluate!(button, "() => window.__clicked") == nil

    click_promise = Task.async(fn -> Locator.click!(button) end)
    visible_promise = Task.async(fn -> Expect.to_be_visible!(button) end)
    Page.evaluate!(page, "() => document.querySelector('iframe').style.visibility = 'visible'")
    Task.await_many([click_promise, visible_promise], :infinity)
    assert Locator.evaluate!(button, "() => window.__clicked") == true

    Page.evaluate!(page, "() => document.querySelector('iframe').style.visibility = 'hidden'")
    Expect.to_be_hidden!(button)
    assert Locator.is_visible!(button) == false
  end

  # https://github.com/microsoft/playwright/issues/42719
  test "should treat elements inside hidden cross-origin iframe as hidden", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(
      page,
      ~s(<iframe style="visibility: hidden" src="#{server.cross_process_prefix}/frames/frame.html"></iframe>)
    )

    div = page |> Page.frame_locator("iframe") |> FrameLocator.locator("div")
    Expect.to_have_text!(div, "Hi, I'm frame")
    assert Locator.is_visible!(div) == false
    Expect.to_be_hidden!(div)

    Page.evaluate!(page, "() => document.querySelector('iframe').style.visibility = 'visible'")
    Expect.to_be_visible!(div)
    assert Locator.is_visible!(div) == true
  end
end
