defmodule PlaywrightEx.Page.LocatorAnyFrameTest do
  @upstream "tests/page/locator-any-frame.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route

  @moduletag :page

  defp route_page(page, url, body) do
    # route.fulfill(...).catch(() => {}): the non-bang form swallows the error.
    Page.route!(page, "**/" <> url, fn route -> Route.fulfill(route, body: body, content_type: "text/html") end)
  end

  defp wait_for_all_frames(page, frame_count, selector) do
    # Wait for all child frames to load their content, so that the search
    # deterministically sees elements in all of them.
    assert poll(fn -> length(Page.frames(page)) end, frame_count)

    for frame <- Page.frames(page), frame != Page.main_frame(page) do
      Frame.wait_for_selector!(frame, selector, state: :attached)
    end
  end

  # expect.poll(fun).toBe(expected)
  defp poll(fun, expected, tries \\ 100) do
    cond do
      fun.() == expected -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(fun, expected, tries - 1)
    end
  end

  defp find_frame(page, part), do: Enum.find(Page.frames(page), &String.contains?(Frame.url(&1), part))

  defp any_frame(page), do: Page.frame_locator(page)

  test "should click a button inside an iframe", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<button onclick="window.__clicked = true">Click me</button>))
    Page.goto!(page, server.empty_page)
    page |> any_frame() |> FrameLocator.get_by_role(:button, name: "Click me") |> Locator.click!()
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window.__clicked") == true
  end

  test "should click a button in the main frame", %{page: page, server: server} do
    route_page(
      page,
      "empty.html",
      ~s(<iframe src="a.html"></iframe><button onclick="window.__clicked = true">Click me</button>)
    )

    route_page(page, "a.html", ~s(<div>No buttons here</div>))
    Page.goto!(page, server.empty_page)
    page |> any_frame() |> FrameLocator.locator("button") |> Locator.click!()
    assert Page.evaluate!(page, "() => window.__clicked") == true
  end

  test "should fail click when elements match in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<button>one</button>))
    route_page(page, "b.html", ~s(<button>two</button>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 3, "button")
    {:error, error} = page |> any_frame() |> FrameLocator.locator("button") |> Locator.click(timeout: 3000)
    assert error.message =~ "frameLocator() matched elements in multiple frames"
    assert error.message =~ "waiting for frameLocator().locator('button')"
  end

  test "should fail click upon strict mode violation inside a single frame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<button>one</button><button>two</button>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "button")
    {:error, error} = page |> any_frame() |> FrameLocator.locator("button") |> Locator.click(timeout: 3000)
    assert error.message =~ "strict mode violation"
    assert error.message =~ "waiting for frameLocator().locator('button')"
  end

  test "should time out on click when there are no matches", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>Nothing here</div>))
    Page.goto!(page, server.empty_page)
    {:error, error} = page |> any_frame() |> FrameLocator.locator("button") |> Locator.click(timeout: 1000)
    assert error.message =~ "Timeout 1000ms exceeded"
    assert error.message =~ "waiting for frameLocator().locator('button')"
  end

  test "should count elements in a single frame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>1</div><div>2</div><div>3</div>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "div")
    assert page |> any_frame() |> FrameLocator.locator("div") |> Locator.count!() == 3
    assert page |> any_frame() |> FrameLocator.locator("button") |> Locator.count!() == 0
  end

  test "should fail count when elements match in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<div>main</div><iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>child</div>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "div")
    {:error, error} = page |> any_frame() |> FrameLocator.locator("div") |> Locator.count()
    assert error.message =~ "frameLocator() matched elements in multiple frames"
  end

  test "should support toHaveCount", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<span>one</span><span>two</span>))
    Page.goto!(page, server.empty_page)
    Expect.to_have_count!(page |> any_frame() |> FrameLocator.locator("span"), 2)
    Expect.to_have_count!(page |> any_frame() |> FrameLocator.locator("button"), 0)
  end

  test "should wait for a frame to appear with toHaveCount", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<div>No frames yet</div>))
    route_page(page, "a.html", ~s(<span>one</span><span>two</span>))
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => {
        const iframe = document.createElement('iframe');
        iframe.src = 'a.html';
        document.body.appendChild(iframe);
      }, 500);
    }
    """)

    Expect.to_have_count!(page |> any_frame() |> FrameLocator.locator("span"), 2)
  end

  test "should fail toHaveCount when elements match in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<span>one</span>))
    route_page(page, "b.html", ~s(<span>two</span>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 3, "span")
    {:error, error} = Expect.to_have_count(page |> any_frame() |> FrameLocator.locator("span"), 2, timeout: 3000)
    assert error.message =~ "frameLocator() matched elements in multiple frames"
    # Elixir syntax: the client renders locators (PLAN).
    assert error.message =~ ~s'Locator: Page.frame_locator(page) |> FrameLocator.locator("span")'
  end

  test "should support toHaveText", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>Hello iframe</div>))
    Page.goto!(page, server.empty_page)
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("div"), "Hello iframe")
  end

  test "should support toHaveText with an array", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<span>one</span><span>two</span>))
    Page.goto!(page, server.empty_page)
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("span"), ["one", "two"])
  end

  test "should fail toHaveText when elements match in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<div>one</div>))
    route_page(page, "b.html", ~s(<div>two</div>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 3, "div")
    {:error, error} = Expect.to_have_text(page |> any_frame() |> FrameLocator.locator("div"), "one", timeout: 3000)
    assert error.message =~ "frameLocator() matched elements in multiple frames"
    # Elixir syntax: the client renders locators (PLAN).
    assert error.message =~ ~s'Locator: Page.frame_locator(page) |> FrameLocator.locator("div")'
  end

  test "should fail toHaveText with an array when elements match in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<span>one</span>))
    route_page(page, "b.html", ~s(<span>two</span>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 3, "span")

    {:error, error} =
      Expect.to_have_text(page |> any_frame() |> FrameLocator.locator("span"), ["one", "two"], timeout: 3000)

    assert error.message =~ "frameLocator() matched elements in multiple frames"
  end

  test "should fail toHaveText upon strict mode violation inside a single frame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>one</div><div>two</div>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "div")
    {:error, error} = Expect.to_have_text(page |> any_frame() |> FrameLocator.locator("div"), "one", timeout: 3000)
    assert error.message =~ "strict mode violation"
    # Elixir syntax: the client renders locators (PLAN).
    assert error.message =~ ~s'Locator: Page.frame_locator(page) |> FrameLocator.locator("div")'
  end

  test "should support evaluate", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div data-foo="bar">Hello</div>))
    Page.goto!(page, server.empty_page)

    assert page |> any_frame() |> FrameLocator.locator("div") |> Locator.evaluate!("e => e.getAttribute('data-foo')") ==
             "bar"
  end

  test "should fail evaluate when elements match in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<div>one</div>))
    route_page(page, "b.html", ~s(<div>two</div>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 3, "div")

    {:error, error} =
      page |> any_frame() |> FrameLocator.locator("div") |> Locator.evaluate("e => e.textContent", nil, timeout: 3000)

    assert error.message =~ "frameLocator() matched elements in multiple frames"
  end

  test "should time out on evaluate when there are no matches", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>Nothing here</div>))
    Page.goto!(page, server.empty_page)

    {:error, error} =
      page
      |> any_frame()
      |> FrameLocator.locator("button")
      |> Locator.evaluate("e => e.textContent", nil, timeout: 1000)

    assert error.message =~ "Timeout 1000ms exceeded"
    assert error.message =~ "waiting for frameLocator().locator('button')"
  end

  test "should support evaluateAll", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<span>one</span><span>two</span>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "span")

    assert page
           |> any_frame()
           |> FrameLocator.locator("span")
           |> Locator.evaluate_all!("els => els.map(e => e.textContent)") ==
             ["one", "two"]

    assert page |> any_frame() |> FrameLocator.locator("button") |> Locator.evaluate_all!("els => els.length") == 0
  end

  test "should fail evaluateAll when elements match in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<span>one</span>))
    route_page(page, "b.html", ~s(<span>two</span>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 3, "span")
    {:error, error} = page |> any_frame() |> FrameLocator.locator("span") |> Locator.evaluate_all("els => els.length")
    assert error.message =~ "frameLocator() matched elements in multiple frames"
  end

  test "should support hasText filter", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>foo</div><div>bar</div>))
    Page.goto!(page, server.empty_page)
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("div", has_text: "bar"), "bar")
  end

  test "should support first/last/nth", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<span>one</span><span>two</span><span>three</span>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "span")
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("span") |> Locator.first(), "one")
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("span") |> Locator.last(), "three")
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("span") |> Locator.nth(1), "two")
  end

  test "should support nth in the middle of the chain", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div><span>one</span></div><div><span>two</span></div>))
    Page.goto!(page, server.empty_page)

    Expect.to_have_text!(
      page |> any_frame() |> FrameLocator.locator("div") |> Locator.nth(1) |> Locator.locator("span"),
      "two"
    )
  end

  test "should support composite locators", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div><span>foo</span></div><div><i>bar</i></div>))
    Page.goto!(page, server.empty_page)
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("div", has: Page.locator(page, "span")), "foo")
  end

  test "should support capture", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div id="target"><span>hello</span></div>))
    Page.goto!(page, server.empty_page)
    Expect.to_have_attribute!(page |> any_frame() |> FrameLocator.locator("*css=div >> span"), "id", "target")
  end

  test "should find a frame inside the scope", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<section><iframe src="a.html"></iframe></section><button>outside</button>))
    route_page(page, "a.html", ~s(<button>inside</button>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "button")
    scope = Page.query_selector!(page, "section")
    buttons = ElementHandle.query_selector_all!(scope, "internal:control=any-frame >> button")
    assert length(buttons) == 1
    assert ElementHandle.text_content!(hd(buttons)) == "inside"
  end

  test "should find a nested frame inside the scope", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<section><iframe src="a.html"></iframe></section><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<iframe src="c.html"></iframe>))
    route_page(page, "b.html", ~s(<button>outside</button>))
    route_page(page, "c.html", ~s(<button>deep</button>))
    Page.goto!(page, server.empty_page)
    assert poll(fn -> length(Page.frames(page)) end, 4)

    for frame <- Page.frames(page),
        String.contains?(Frame.url(frame), "b.html") or String.contains?(Frame.url(frame), "c.html") do
      Frame.wait_for_selector!(frame, "button", state: :attached)
    end

    scope = Page.query_selector!(page, "section")
    buttons = ElementHandle.query_selector_all!(scope, "internal:control=any-frame >> button")
    assert length(buttons) == 1
    assert ElementHandle.text_content!(hd(buttons)) == "deep"
  end

  test "should find a frame inside the scope while another iframe is stalled", %{page: page, server: server} do
    route_page(
      page,
      "empty.html",
      ~s(<section><iframe src="a.html"></iframe><iframe src="stall.html"></iframe></section>)
    )

    route_page(page, "a.html", ~s(<button>inside</button>))
    Page.route!(page, "**/stall.html", fn _route -> nil end)
    Page.goto!(page, server.empty_page, wait_until: :domcontentloaded)
    assert poll(fn -> length(Page.frames(page)) end, 3)
    scope = Page.query_selector!(page, "section")
    buttons = ElementHandle.query_selector_all!(scope, "internal:control=any-frame >> button")
    assert length(buttons) == 1
    assert ElementHandle.text_content!(hd(buttons)) == "inside"
  end

  test "should respect the scope without a frame inside the scope", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<section><button>target</button></section><iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<button>in-frame</button>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "button")
    scope = Page.query_selector!(page, "section")
    buttons = ElementHandle.query_selector_all!(scope, "internal:control=any-frame >> button")
    assert length(buttons) == 1
    assert ElementHandle.text_content!(hd(buttons)) == "target"
  end

  test "should not match a chain across a frame boundary", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<section><iframe src="a.html"></iframe></section>))
    route_page(page, "a.html", ~s(<iframe src="b.html"></iframe>))
    route_page(page, "b.html", ~s(<button>deep</button>))
    Page.goto!(page, server.empty_page)
    assert poll(fn -> length(Page.frames(page)) end, 3)
    deep_frame = find_frame(page, "b.html")
    Frame.wait_for_selector!(deep_frame, "button", state: :attached)
    # "section" lives in the main frame, while the button is two frames below it.
    Expect.to_have_count!(page |> any_frame() |> FrameLocator.locator("section") |> Locator.locator("button"), 0)
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("button"), "deep")
  end

  test "should only search frames inside the starting frame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><button>main</button>))
    route_page(page, "a.html", ~s(<iframe src="b.html"></iframe>))
    route_page(page, "b.html", ~s(<button>deep</button>))
    Page.goto!(page, server.empty_page)
    assert poll(fn -> length(Page.frames(page)) end, 3)
    deep_frame = find_frame(page, "b.html")
    Frame.wait_for_selector!(deep_frame, "button", state: :attached)
    middle_frame = find_frame(page, "a.html")
    Expect.to_have_text!(middle_frame |> Frame.frame_locator() |> FrameLocator.locator("button"), "deep")
  end

  test "should enter a frame found in a nested frame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><button>main</button>))
    route_page(page, "a.html", ~s(<iframe id="target" src="b.html"></iframe><button>decoy</button>))
    route_page(page, "b.html", ~s(<button>inside</button>))
    Page.goto!(page, server.empty_page)

    Expect.to_have_text!(
      page |> any_frame() |> FrameLocator.frame_locator("#target") |> FrameLocator.locator("button"),
      "inside"
    )
  end

  test "should click inside an entered frame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<iframe id="target" src="b.html"></iframe><button>Click me</button>))
    route_page(page, "b.html", ~s(<button onclick="window.__clicked = true">Click me</button>))
    Page.goto!(page, server.empty_page)

    page
    |> any_frame()
    |> FrameLocator.frame_locator("#target")
    |> FrameLocator.get_by_role(:button, name: "Click me")
    |> Locator.click!()

    frame = find_frame(page, "b.html")
    assert Frame.evaluate!(frame, "() => window.__clicked") == true
  end

  test "should not search nested frames after entering a frame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe id="target" src="a.html"></iframe><button>main</button>))
    route_page(page, "a.html", ~s(<iframe src="b.html"></iframe>))
    route_page(page, "b.html", ~s(<button>deep</button>))
    Page.goto!(page, server.empty_page)
    assert poll(fn -> length(Page.frames(page)) end, 3)
    # The entered frame itself has no button, and we do not look inside its nested frames.
    Expect.to_have_count!(
      page |> any_frame() |> FrameLocator.frame_locator("#target") |> FrameLocator.locator("button"),
      0
    )
  end

  test "should support two frameLocators", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<iframe id="x" src="b.html"></iframe>))
    route_page(page, "b.html", ~s(<iframe id="y" src="c.html"></iframe><button>decoy</button>))
    route_page(page, "c.html", ~s(<button>bottom</button>))
    Page.goto!(page, server.empty_page)

    Expect.to_have_text!(
      page
      |> any_frame()
      |> FrameLocator.frame_locator("#x")
      |> FrameLocator.frame_locator("#y")
      |> FrameLocator.locator("button"),
      "bottom"
    )
  end

  test "should support locator before frameLocator", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<section><iframe src="b.html"></iframe></section><iframe src="c.html"></iframe>))
    route_page(page, "b.html", ~s(<button>in-section</button>))
    route_page(page, "c.html", ~s(<button>outside</button>))
    Page.goto!(page, server.empty_page)

    Expect.to_have_text!(
      page
      |> any_frame()
      |> FrameLocator.locator("section")
      |> Locator.frame_locator("iframe")
      |> FrameLocator.locator("button"),
      "in-section"
    )
  end

  test "should support owner of a frameLocator", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<iframe id="target" src="b.html"></iframe>))
    route_page(page, "b.html", ~s(<button>inside</button>))
    Page.goto!(page, server.empty_page)

    assert page
           |> any_frame()
           |> FrameLocator.frame_locator("#target")
           |> FrameLocator.owner()
           |> Locator.get_attribute!("id") == "target"
  end

  test "should wait for the frame to enter to appear", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div>Nothing yet</div>))
    route_page(page, "b.html", ~s(<button>late</button>))
    Page.goto!(page, server.empty_page)
    assert poll(fn -> length(Page.frames(page)) end, 2)

    Frame.evaluate!(Enum.at(Page.frames(page), 1), """
    () => {
      window.builtins.setTimeout(() => {
        const iframe = document.createElement('iframe');
        iframe.id = 'late';
        iframe.src = 'b.html';
        document.body.appendChild(iframe);
      }, 3000);
    }
    """)

    Expect.to_have_text!(
      page |> any_frame() |> FrameLocator.frame_locator("#late") |> FrameLocator.locator("button"),
      "late"
    )
  end

  test "should fail when the frame to enter matches in multiple frames", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="b.html"></iframe>))
    route_page(page, "a.html", ~s(<iframe class="inner" src="c.html"></iframe>))
    route_page(page, "b.html", ~s(<iframe class="inner" src="c.html"></iframe>))
    route_page(page, "c.html", ~s(<button>Click me</button>))
    Page.goto!(page, server.empty_page)
    assert poll(fn -> length(Page.frames(page)) end, 5)

    for frame <- Page.frames(page), String.contains?(Frame.url(frame), "c.html") do
      Frame.wait_for_selector!(frame, "button", state: :attached)
    end

    {:error, error} =
      page
      |> any_frame()
      |> FrameLocator.frame_locator(".inner")
      |> FrameLocator.locator("button")
      |> Locator.click(timeout: 3000)

    assert error.message =~ "frameLocator() matched elements in multiple frames"
  end

  test "should support contentFrame", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<iframe id="target" src="b.html"></iframe><button>decoy</button>))
    route_page(page, "b.html", ~s(<button>inside</button>))
    Page.goto!(page, server.empty_page)

    Expect.to_have_text!(
      page
      |> any_frame()
      |> FrameLocator.locator("#target")
      |> Locator.content_frame()
      |> FrameLocator.locator("button"),
      "inside"
    )
  end

  test "should render frameLocator() in the locator description", %{page: page} do
    # Elixir syntax: the client renders locators (PLAN).
    assert page
           |> any_frame()
           |> FrameLocator.frame_locator("#x")
           |> FrameLocator.locator("button")
           |> Locator.to_string() ==
             ~s'Page.frame_locator(page) |> FrameLocator.locator("#x") |> Locator.content_frame() |> FrameLocator.locator("button")'

    assert page
           |> any_frame()
           |> FrameLocator.locator("section")
           |> Locator.frame_locator("iframe")
           |> FrameLocator.get_by_text("foo")
           |> Locator.to_string() ==
             ~s'Page.frame_locator(page) |> FrameLocator.locator("section") |> Locator.locator("iframe") |> Locator.content_frame() |> FrameLocator.get_by_text("foo")'
  end

  test "should not allow frameLocator() inside a composite locator", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<button>main</button><iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<a href="#">link</a>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "a")

    {:error, error} =
      page
      |> Page.locator("button")
      |> Locator.or_(page |> any_frame() |> FrameLocator.locator("a"))
      |> Locator.count()

    assert error.message =~
             ~s{frameLocator() is not allowed inside composite locators, while querying "locator('button').or(frameLocator().locator('a'))"}

    {:error, error2} =
      page
      |> Page.locator("button")
      |> Locator.filter(has: page |> any_frame() |> FrameLocator.locator("a"))
      |> Locator.count()

    assert error2.message =~ "frameLocator() is not allowed inside composite locators"

    # Repeating frameLocator() in the operand is not allowed either, even though the outer locator has it.
    {:error, error3} =
      page
      |> any_frame()
      |> FrameLocator.locator("button")
      |> Locator.or_(page |> any_frame() |> FrameLocator.locator("a"))
      |> Locator.count()

    assert error3.message =~
             ~s{frameLocator() is not allowed inside composite locators, while querying "frameLocator().locator('button').or(frameLocator().locator('a'))"}

    # Repeating frameLocator() is not allowed even when the rest of the frame chain matches.
    {:error, error4} =
      page
      |> any_frame()
      |> FrameLocator.frame_locator("#f")
      |> FrameLocator.locator("a")
      |> Locator.or_(page |> any_frame() |> FrameLocator.frame_locator("#f") |> FrameLocator.locator("button"))
      |> Locator.count()

    assert error4.message =~ "frameLocator() is not allowed inside composite locators"

    # With frameLocator() first, the token applies to the whole locator, so both operands are searched in every frame.
    {:error, error5} =
      page
      |> any_frame()
      |> FrameLocator.locator("a")
      |> Locator.or_(Page.locator(page, "button"))
      |> Locator.count()

    assert error5.message =~ "frameLocator() matched elements in multiple frames"
  end

  test "should support a composite locator under frameLocator()", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<div class="classname">first</div><button>second</button>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "button")

    Expect.to_have_text!(
      page |> any_frame() |> FrameLocator.locator(".classname") |> Locator.or_(Page.get_by_role(page, :button)),
      ["first", "second"]
    )
  end

  test "should support a composite locator under frameLocator() and a frame locator", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<iframe id="f" src="b.html"></iframe>))
    route_page(page, "b.html", ~s(<div class="classname">first</div><button>second</button>))
    Page.goto!(page, server.empty_page)
    assert poll(fn -> length(Page.frames(page)) end, 3)

    Expect.to_have_text!(
      page
      |> any_frame()
      |> FrameLocator.frame_locator("#f")
      |> FrameLocator.locator(".classname")
      |> Locator.or_(page |> Page.frame_locator("#f") |> FrameLocator.get_by_role(:button)),
      ["first", "second"]
    )
  end

  test "should not allow first/last/nth on frameLocator()", %{page: page} do
    message = ~r/Selecting the nth frame is not allowed on frameLocator\(\)/
    assert_raise RuntimeError, message, fn -> page |> any_frame() |> FrameLocator.first() end
    assert_raise RuntimeError, message, fn -> page |> any_frame() |> FrameLocator.last() end
    assert_raise RuntimeError, message, fn -> page |> any_frame() |> FrameLocator.nth(1) end
  end

  test "should not allow owner on frameLocator()", %{page: page} do
    {:error, error} = page |> any_frame() |> FrameLocator.owner() |> Locator.count()
    assert error.message =~ "Selector cannot be empty after frameLocator()"
  end

  test "should resolve aria-ref selectors", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<button>main</button><iframe src="a.html"></iframe>))
    route_page(page, "a.html", ~s(<button>inside</button>))
    Page.goto!(page, server.empty_page)
    wait_for_all_frames(page, 2, "button")
    snapshot = Page.aria_snapshot!(page, mode: :ai)
    # Refs are unique across frames, so every starting frame resolves them to the same element.
    [_, inside_ref] = Regex.run(~r/button "inside" \[ref=(.*?)\]/, snapshot)
    assert inside_ref =~ ~r/^f\d+e\d+$/
    Expect.to_have_text!(page |> any_frame() |> FrameLocator.locator("aria-ref=#{inside_ref}"), "inside")
  end

  test "should click while another iframe is stalled", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="stall.html"></iframe>))
    route_page(page, "a.html", ~s(<button onclick="window.__clicked = true">Click me</button>))
    Page.route!(page, "**/stall.html", fn _route -> nil end)
    Page.goto!(page, server.empty_page, wait_until: :domcontentloaded)
    assert poll(fn -> length(Page.frames(page)) end, 3)
    page |> any_frame() |> FrameLocator.locator("button") |> Locator.click!()
    frame = find_frame(page, "a.html")
    assert Frame.evaluate!(frame, "() => window.__clicked") == true
  end

  test "should support toBeVisible while another iframe is stalled", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="stall.html"></iframe>))
    route_page(page, "a.html", ~s(<button>Click me</button>))
    Page.route!(page, "**/stall.html", fn _route -> nil end)
    Page.goto!(page, server.empty_page, wait_until: :domcontentloaded)
    assert poll(fn -> length(Page.frames(page)) end, 3)
    Expect.to_be_visible!(page |> any_frame() |> FrameLocator.locator("button"))
  end

  test "should support toHaveCount while another iframe is stalled", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html"></iframe><iframe src="stall.html"></iframe>))
    route_page(page, "a.html", ~s(<button>Click me</button>))
    Page.route!(page, "**/stall.html", fn _route -> nil end)
    Page.goto!(page, server.empty_page, wait_until: :domcontentloaded)
    assert poll(fn -> length(Page.frames(page)) end, 3)
    Expect.to_have_count!(page |> any_frame() |> FrameLocator.locator("button"), 1)
  end

  test "should treat elements inside hidden iframe as hidden", %{page: page, server: server} do
    route_page(page, "empty.html", ~s(<iframe src="a.html" style="visibility: hidden"></iframe>))
    route_page(page, "a.html", ~s(<button onclick="window.__clicked = true">Click me</button>))
    Page.goto!(page, server.empty_page)
    button = page |> any_frame() |> FrameLocator.locator("button")
    Expect.to_be_attached!(button)
    assert Locator.is_visible!(button) == false
    Expect.to_be_hidden!(button)

    {:error, error} = Locator.click(button, timeout: 1000)
    assert error.message =~ "element is inside a hidden frame, retrying"
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window.__clicked") == nil

    Page.evaluate!(page, "() => document.querySelector('iframe').style.visibility = 'visible'")
    Expect.to_be_visible!(button)
    Locator.click!(button)
    assert Frame.evaluate!(Enum.at(Page.frames(page), 1), "() => window.__clicked") == true
  end
end
