defmodule PlaywrightEx.Page.SelectorsFrameTest do
  @upstream "tests/page/selectors-frame.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime

  @moduletag :page

  defp route_iframe(page) do
    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill(route, body: ~s(<iframe src="iframe.html"></iframe>), content_type: "text/html")
    end)

    Page.route!(page, "**/iframe.html", fn route ->
      Route.fulfill(route,
        body: """
                <html>
                  <div>
                    <button>Hello iframe</button>
                    <iframe src="iframe-2.html"></iframe>
                  </div>
                  <span>1</span>
                  <span>2</span>
                </html>
        """,
        content_type: "text/html"
      )
    end)

    Page.route!(page, "**/iframe-2.html", fn route ->
      Route.fulfill(route,
        body: ~s(<html><button tag="iframe2">Hello nested iframe</button></html>),
        content_type: "text/html"
      )
    end)
  end

  test "SE-098 should work for iframe @smoke", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = Page.locator(page, "iframe >> internal:control=enter-frame >> button")
    Locator.wait_for!(button)
    assert Locator.inner_text!(button) == "Hello iframe"
    Expect.to_have_text!(button, "Hello iframe")
    Locator.click!(button)
  end

  test "SE-099 should work for iframe (handle)", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    body = Page.query_selector!(page, "body")
    button = ElementHandle.wait_for_selector!(body, "iframe >> internal:control=enter-frame >> button")
    assert ElementHandle.inner_text!(button) == "Hello iframe"
    assert ElementHandle.text_content!(button) == "Hello iframe"
    ElementHandle.click!(button)
  end

  test "SE-100 should work for nested iframe", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)

    button =
      Page.locator(
        page,
        "iframe >> internal:control=enter-frame >> iframe >> internal:control=enter-frame >> button"
      )

    Locator.wait_for!(button)
    assert Locator.inner_text!(button) == "Hello nested iframe"
    Expect.to_have_text!(button, "Hello nested iframe")
    Locator.click!(button)
  end

  test "SE-101 should work for nested iframe (handle)", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    body = Page.query_selector!(page, "body")

    button =
      ElementHandle.wait_for_selector!(
        body,
        "iframe >> internal:control=enter-frame >> iframe >> internal:control=enter-frame >> button"
      )

    assert ElementHandle.inner_text!(button) == "Hello nested iframe"
    assert ElementHandle.text_content!(button) == "Hello nested iframe"
    ElementHandle.click!(button)
  end

  test "SE-102 should work for $ and $$", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    element = Page.query_selector!(page, "iframe >> internal:control=enter-frame >> button")
    assert ElementHandle.text_content!(element) == "Hello iframe"
    elements = Page.query_selector_all!(page, "iframe >> internal:control=enter-frame >> span")
    assert length(elements) == 2
  end

  test "SE-103 $ should not wait for frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    refute Page.query_selector!(page, "iframe >> internal:control=enter-frame >> canvas")
    body = Page.query_selector!(page, "body")
    refute ElementHandle.query_selector!(body, "iframe >> internal:control=enter-frame >> canvas")
  end

  test "SE-104 $$ should not wait for frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert Page.query_selector_all!(page, "iframe >> internal:control=enter-frame >> canvas") == []
    body = Page.query_selector!(page, "body")
    assert ElementHandle.query_selector_all!(body, "iframe >> internal:control=enter-frame >> canvas") == []
  end

  test "SE-105 $eval should throw for missing frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    {:error, error} = Page.eval_on_selector(page, "iframe >> internal:control=enter-frame >> canvas", "e => 1")
    assert error.message =~ "page.$eval: Failed to find element matching selector"

    body = Page.query_selector!(page, "body")

    {:error, error} =
      ElementHandle.eval_on_selector(body, "iframe >> internal:control=enter-frame >> canvas", "e => 1")

    assert error.message =~ "elementHandle.$eval: Failed to find element matching selector"
  end

  test "SE-106 $$eval should not throw for missing frame", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    assert Page.eval_on_selector_all!(page, "iframe >> internal:control=enter-frame >> canvas", "e => e.length") ==
             0

    body = Page.query_selector!(page, "body")

    assert ElementHandle.eval_on_selector_all!(
             body,
             "iframe >> internal:control=enter-frame >> canvas",
             "e => e.length"
           ) == 0
  end

  test "SE-107 should work for $ and $$ (handle)", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    body = Page.query_selector!(page, "body")
    element = ElementHandle.query_selector!(body, "iframe >> internal:control=enter-frame >> button")
    assert ElementHandle.text_content!(element) == "Hello iframe"
    elements = ElementHandle.query_selector_all!(body, "iframe >> internal:control=enter-frame >> span")
    assert length(elements) == 2
  end

  test "SE-108 should work for $eval", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    value = Page.eval_on_selector!(page, "iframe >> internal:control=enter-frame >> button", "b => b.nodeName")
    assert value == "BUTTON"
  end

  test "SE-109 should work for $eval (handle)", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    body = Page.query_selector!(page, "body")

    value =
      ElementHandle.eval_on_selector!(body, "iframe >> internal:control=enter-frame >> button", "b => b.nodeName")

    assert value == "BUTTON"
  end

  test "SE-110 should work for $$eval", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)

    value =
      Page.eval_on_selector_all!(
        page,
        "iframe >> internal:control=enter-frame >> span",
        "ss => ss.map(s => s.textContent)"
      )

    assert value == ["1", "2"]
  end

  test "SE-111 should work for $$eval (handle)", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    body = Page.query_selector!(page, "body")

    value =
      ElementHandle.eval_on_selector_all!(
        body,
        "iframe >> internal:control=enter-frame >> span",
        "ss => ss.map(s => s.textContent)"
      )

    assert value == ["1", "2"]
  end

  test "SE-112 should not allow dangling enter-frame", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = Page.locator(page, "iframe >> internal:control=enter-frame")
    {:error, error} = Locator.click(button)
    assert error.message =~ "Selector cannot end with"
    assert error.message =~ "iframe >> internal:control=enter-frame"
  end

  test "SE-113 should not allow leading enter-frame", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    {:error, error} = Page.wait_for_selector(page, "internal:control=enter-frame >> button")
    assert error.message =~ "Selector cannot start with"
  end

  test "SE-114 should not allow capturing before enter-frame", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    button = Page.locator(page, "*css=iframe >> internal:control=enter-frame >> div")
    {:error, error} = Locator.click(button)
    assert error.message =~ "Can not capture the selector before diving into the frame"
  end

  test "SE-115 should capture after the enter-frame", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    div = Page.locator(page, "iframe >> internal:control=enter-frame >> *css=div >> button")
    assert Locator.inner_html!(div) =~ "<button>"
  end

  test "SE-116 should click in lazy iframe", %{page: page, server: server} do
    Page.route!(page, "**/iframe.html", fn route ->
      Route.fulfill(route, body: "<html><button>Hello iframe</button></html>", content_type: "text/html")
    end)

    # empty pge
    Page.goto!(page, server.empty_page)

    # add blank iframe
    Task.start(fn ->
      Process.sleep(500)

      Runtime.Promise.void(fn ->
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
    button = Page.locator(page, "iframe >> internal:control=enter-frame >> button")

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

  test "SE-117 waitFor should survive frame reattach", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)

    button =
      Page.locator(page, ~s|iframe >> internal:control=enter-frame >> button:has-text("Hello nested iframe")|)

    promise = Runtime.Promise.async(fn -> Locator.wait_for!(button) end)
    Locator.evaluate!(Page.locator(page, "iframe"), "e => e.remove()")

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = 'iframe-2.html';
      document.body.appendChild(iframe);
    }
    """)

    Runtime.Promise.await(promise)
  end

  test "SE-118 waitForSelector should survive frame reattach (handle)", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    body = Page.query_selector!(page, "body")

    promise =
      Runtime.Promise.async(fn ->
        ElementHandle.wait_for_selector!(
          body,
          ~s|iframe >> internal:control=enter-frame >> button:has-text("Hello nested iframe")|
        )
      end)

    Locator.evaluate!(Page.locator(page, "iframe"), "e => e.remove()")

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = 'iframe-2.html';
      document.body.appendChild(iframe);
    }
    """)

    Runtime.Promise.await(promise)
  end

  test "SE-119 waitForSelector should survive iframe navigation (handle)", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    body = Page.query_selector!(page, "body")

    promise =
      Runtime.Promise.async(fn ->
        ElementHandle.wait_for_selector!(
          body,
          ~s|iframe >> internal:control=enter-frame >> button:has-text("Hello nested iframe")|
        )
      end)

    Runtime.Promise.void(fn -> Locator.evaluate(Page.locator(page, "iframe"), "e => e.src = 'iframe-2.html'") end)
    Runtime.Promise.await(promise)
  end

  test "SE-120 click should survive frame reattach", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)

    button =
      Page.locator(page, ~s|iframe >> internal:control=enter-frame >> button:has-text("Hello nested iframe")|)

    promise = Runtime.Promise.async(fn -> Locator.click!(button) end)
    Locator.evaluate!(Page.locator(page, "iframe"), "e => e.remove()")

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = 'iframe-2.html';
      document.body.appendChild(iframe);
    }
    """)

    Runtime.Promise.await(promise)
  end

  test "SE-121 click should survive iframe navigation", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)

    button =
      Page.locator(page, ~s|iframe >> internal:control=enter-frame >> button:has-text("Hello nested iframe")|)

    promise = Runtime.Promise.async(fn -> Locator.click!(button) end)
    Runtime.Promise.void(fn -> Locator.evaluate(Page.locator(page, "iframe"), "e => e.src = 'iframe-2.html'") end)
    Runtime.Promise.await(promise)
  end

  test "SE-122 click should survive navigation", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.prefix <> "/iframe.html")
    promise = Runtime.Promise.async(fn -> Page.click!(page, ~s|button:has-text("Hello nested iframe")|) end)
    Page.wait_for_timeout!(page, 100)
    Page.goto!(page, server.prefix <> "/iframe-2.html")
    Runtime.Promise.await(promise)
  end

  test "SE-123 should non work for non-frame", %{page: page} do
    route_iframe(page)
    Page.set_content!(page, "<div></div>")
    button = Page.locator(page, "div >> internal:control=enter-frame >> button")
    {:error, error} = Locator.wait_for(button)
    assert error.message =~ "<div></div>"
    assert error.message =~ "<iframe> was expected"
  end

  test "SE-124 should match in a descendant frame", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    # The main frame has no <div>; only the iframe.html child frame does.
    div = Page.locator(page, "internal:control=any-frame >> div")
    Locator.wait_for!(div)
    Expect.to_have_count!(div, 1)
    assert Locator.inner_html!(div) =~ "<button>Hello iframe</button>"
  end

  test "SE-125 should match in a deeply nested frame", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    # The main frame has no <div>; only the iframe.html child frame does.
    button = Page.locator(page, ~s(internal:control=any-frame >> button[tag="iframe2"]))
    Locator.wait_for!(button)
    Expect.to_have_count!(button, 1)
    assert Locator.text_content!(button) == "Hello nested iframe"
  end

  test "SE-126 should not match a chain across frames", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    # The <div> lives in the iframe.html frame, while the button lives in the frame nested below it.
    Expect.to_have_count!(Page.locator(page, ~s(internal:control=any-frame >> div >> button[tag="iframe2"])), 0)
    Expect.to_have_text!(Page.locator(page, "internal:control=any-frame >> div >> button"), "Hello iframe")
  end

  test "SE-127 should match multiple elements", %{page: page, server: server} do
    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill(route,
        body: ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>),
        content_type: "text/html"
      )
    end)

    Page.route!(page, "**/a.html", fn route ->
      Route.fulfill(route, body: "<div>one</div>", content_type: "text/html")
    end)

    Page.route!(page, "**/b.html", fn route ->
      Route.fulfill(route, body: "<span>two</span><span>three</span>", content_type: "text/html")
    end)

    Page.goto!(page, server.empty_page)

    texts =
      Page.eval_on_selector_all!(page, "internal:control=any-frame >> span", "els => els.map(e => e.textContent)")

    assert texts == ["two", "three"]
  end

  test "SE-128 should throw when matching elements in multiple frames", %{page: page, server: server} do
    Page.route!(page, "**/empty.html", fn route ->
      Route.fulfill(route,
        body: ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>),
        content_type: "text/html"
      )
    end)

    Page.route!(page, "**/a.html", fn route ->
      Route.fulfill(route, body: "<div>one</div>", content_type: "text/html")
    end)

    Page.route!(page, "**/b.html", fn route ->
      Route.fulfill(route, body: "<div>two</div>", content_type: "text/html")
    end)

    Page.goto!(page, server.empty_page)

    # Make sure both child frames have their <div> before matching, otherwise resolution
    # may transiently collapse to a single frame.
    Expect.poll!(fn -> length(Page.frames(page)) end, &assert(&1 == 3))

    for frame <- Page.frames(page), frame != Page.main_frame(page) do
      Frame.wait_for_selector!(frame, "div")
    end

    {:error, error} = Locator.inner_html(Page.locator(page, "internal:control=any-frame >> div"))
    assert error.message =~ "frameLocator() matched elements in multiple frames"
  end

  test "SE-129 should not allow any-frame in the middle of a selector", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)
    {:error, error} = Locator.wait_for(Page.locator(page, "iframe >> internal:control=any-frame >> div"))
    assert error.message =~ ~s("any-frame" is only allowed as the first selector token)
  end

  test "SE-130 should allow entering frames from any frame", %{page: page, server: server} do
    route_iframe(page)
    Page.goto!(page, server.empty_page)

    button =
      Page.locator(
        page,
        ~s(internal:control=any-frame >> iframe[src="iframe-2.html"] >> internal:control=enter-frame >> button)
      )

    Locator.wait_for!(button)
    assert Locator.inner_text!(button) == "Hello nested iframe"
  end

  test "SE-131 should not allow any-frame after entering a frame", %{page: page} do
    {:error, error} =
      Locator.count(
        Page.locator(page, "iframe >> internal:control=enter-frame >> internal:control=any-frame >> button")
      )

    assert error.message =~ ~s("any-frame" is only allowed as the first selector token)
  end

  test "SE-132 should not allow dangling enter-frame after any-frame", %{page: page} do
    {:error, error} =
      Locator.count(Page.locator(page, "internal:control=any-frame >> iframe >> internal:control=enter-frame"))

    assert error.message =~ "Selector cannot end with entering frame"
  end
end
