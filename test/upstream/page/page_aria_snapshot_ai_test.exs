defmodule PlaywrightEx.Page.PageAriaSnapshotAiTest do
  @upstream "tests/page/page-aria-snapshot-ai.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp snapshot_for_ai(page, options \\ []), do: Page.aria_snapshot!(page, Keyword.put(options, :mode, "ai"))

  # `expect(received).toContainYaml(expected)` (pageTest.ts): strips the common indentation.
  defp assert_contain_yaml(received, expected) do
    trimmed = expected |> String.split("\n") |> Enum.filter(&(String.trim(&1) != ""))
    max_prefix_length = trimmed |> Enum.map(&indentation/1) |> Enum.min()
    trimmed_expected = Enum.map_join(trimmed, "\n", &String.slice(&1, max_prefix_length..-1//1))
    assert received =~ trimmed_expected
  end

  # `unshift(snapshot)` (tests/config/utils.ts).
  defp unshift(snapshot) do
    lines = String.split(snapshot, "\n")
    prefix = lines |> Enum.reject(&(String.trim(&1) == "")) |> Enum.map(&indentation/1) |> Enum.reduce(100, &min/2)
    lines |> Enum.filter(&(String.trim(&1) != "")) |> Enum.map_join("\n", &String.slice(&1, prefix..-1//1))
  end

  defp indentation(line), do: String.length(line) - String.length(String.trim_leading(line))

  defp html_route(server, path, body) do
    TestServer.set_route(server, path, fn conn ->
      conn |> Plug.Conn.put_resp_header("content-type", "text/html") |> Plug.Conn.send_resp(200, body)
    end)
  end

  test "should generate refs", %{page: page} do
    Page.set_content!(page, """
      <button>One</button>
      <button>Two</button>
      <button>Three</button>
    """)

    snapshot1 = snapshot_for_ai(page)

    assert_contain_yaml(snapshot1, """
      - generic [active] [ref=e1]:
        - button "One" [ref=e2]
        - button "Two" [ref=e3]
        - button "Three" [ref=e4]
    """)

    Expect.to_have_text!(Page.get_by_ref(page, "e2"), "One")
    Expect.to_have_text!(Page.get_by_ref(page, "e3"), "Two")
    Expect.to_have_text!(Page.get_by_ref(page, "e4"), "Three")

    Locator.evaluate!(Page.get_by_ref(page, "e3"), "e => { e.textContent = 'Not Two'; }")

    snapshot2 = snapshot_for_ai(page)

    assert_contain_yaml(snapshot2, """
      - generic [active] [ref=e1]:
        - button "One" [ref=e2]
        - button "Not Two" [ref=e5]
        - button "Three" [ref=e4]
    """)
  end

  test "should list iframes", %{page: page} do
    Page.set_content!(page, """
      <h1>Hello</h1>
      <iframe name="foo" src="data:text/html,<h1>World</h1>">
    """)

    snapshot1 = snapshot_for_ai(page)
    assert snapshot1 =~ "- iframe"

    frame_snapshot = page |> Page.frame_locator("iframe") |> FrameLocator.locator("body") |> Locator.aria_snapshot!()
    assert frame_snapshot == ~s(- heading "World" [level=1])
  end

  test "should snapshot a locator inside an iframe", %{page: page} do
    Page.set_content!(page, """
      <h1>Main Page</h1>
      <iframe srcdoc="<ul><li>Item 1</li><li>Item 2</li></ul>"></iframe>
    """)

    list = page |> Page.frames() |> Enum.at(1) |> Frame.locator("ul")
    snapshot = Locator.aria_snapshot!(list, mode: "ai")

    assert_contain_yaml(snapshot, """
      - list [ref=f1e1]:
        - listitem [ref=f1e2]: Item 1
        - listitem [ref=f1e3]: Item 2
    """)
  end

  test "should limit depth across iframe boundary", %{page: page} do
    Page.set_content!(page, """
      <nav>
        <iframe srcdoc="<ul><li><button>Deep</button></li></ul>"></iframe>
      </nav>
    """)

    snapshot = snapshot_for_ai(page, depth: 3)

    assert_contain_yaml(snapshot, """
      - navigation [ref=e2]:
        - iframe [ref=e3]:
          - list [ref=f1e2]:
            - listitem [ref=f1e3]
    """)

    refute snapshot =~ "button"
  end

  test "should stitch all frame snapshots", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/nested-frames.html")
    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - iframe [ref=e2]:
          - generic [ref=f1e1]:
            - iframe [ref=f1e2]:
              - generic [ref=f3e1]: Hi, I'm frame
            - iframe [ref=f1e3]:
              - generic [ref=f4e1]: Hi, I'm frame
        - iframe [ref=e3]:
          - generic [ref=f2e1]: Hi, I'm frame
    """)

    href = Locator.evaluate!(Page.get_by_ref(page, "e1"), "e => e.ownerDocument.defaultView.location.href")
    assert href == server.prefix <> "/frames/nested-frames.html"

    href2 = Locator.evaluate!(Page.get_by_ref(page, "f1e2"), "e => e.ownerDocument.defaultView.location.href")
    assert href2 == server.prefix <> "/frames/two-frames.html"

    href3 = Locator.evaluate!(Page.get_by_ref(page, "f4e2"), "e => e.ownerDocument.defaultView.location.href")
    assert href3 == server.prefix <> "/frames/frame.html"

    resolved = Locator.normalize!(Page.get_by_ref(page, "e1"))
    # Elixir syntax: the client renders locators (PLAN).
    assert Locator.to_string(resolved) == ~s'Page.locator(page, "body")'

    resolved = Locator.normalize!(Page.get_by_ref(page, "f4e2"))

    assert Locator.to_string(resolved) ==
             ~S{Page.locator(page, "iframe[name=\"2frames\"]") |> Locator.content_frame() |> FrameLocator.locator("iframe[name=\"dos\"]") |> Locator.content_frame() |> FrameLocator.get_by_text("Hi, I'm frame")}

    # Should tolerate .describe().
    resolved = page |> Page.get_by_ref("f3e2") |> Locator.describe("foo bar") |> Locator.normalize!()

    assert Locator.to_string(resolved) ==
             ~S{Page.locator(page, "iframe[name=\"2frames\"]") |> Locator.content_frame() |> FrameLocator.locator("iframe[name=\"uno\"]") |> Locator.content_frame() |> FrameLocator.get_by_text("Hi, I'm frame")}

    {:error, error} = Locator.normalize(Page.get_by_ref(page, "e1000"))
    assert Exception.message(error) =~ "No element matching aria-ref=e1000"
  end

  test "should re-number refs across navigations but not same-document navigations", %{page: page, server: server} do
    html_route(server, "/one.html", "<button>One</button>")
    html_route(server, "/two.html", "<button>Two</button>")

    # The first committed document keeps the base seq, so the main frame has no prefix.
    Page.goto!(page, server.prefix <> "/one.html")
    [one_ref] = Regex.run(~r/button "One" \[ref=(e\d+)\]/, snapshot_for_ai(page), capture: :all_but_first)
    Expect.to_have_text!(Page.get_by_ref(page, one_ref), "One")

    # Cross-document navigation re-numbers the main frame, so its refs gain a frame prefix.
    Page.goto!(page, server.prefix <> "/two.html")
    [two_ref] = Regex.run(~r/button "Two" \[ref=(f\d+e\d+)\]/, snapshot_for_ai(page), capture: :all_but_first)
    Expect.to_have_text!(Page.get_by_ref(page, two_ref), "Two")

    # The stale ref from the previous document must not resolve against the new one.
    {:error, error} = Locator.normalize(Page.get_by_ref(page, one_ref))
    assert Exception.message(error) =~ "No element matching aria-ref=#{one_ref}"

    # Same-document navigation keeps refs intact.
    Page.evaluate!(page, "() => history.pushState({}, '', '/pushed.html')")
    assert snapshot_for_ai(page) =~ ~s(button "Two" [ref=#{two_ref}])
    Expect.to_have_text!(Page.get_by_ref(page, two_ref), "Two")
  end

  test "should persist iframe references", %{page: page} do
    Page.set_content!(page, """
      <ul>
        <li><iframe srcdoc="<button>button1</button>"></iframe></li>
        <li><iframe srcdoc="<button>button2</button>"></iframe></li>
      </ul>
    """)

    assert_contain_yaml(snapshot_for_ai(page), """
      - list [ref=e2]:
        - listitem [ref=e3]:
          - iframe [ref=e4]:
            - button "button1" [ref=f1e2]
        - listitem [ref=e5]:
          - iframe [ref=e6]:
            - button "button2" [ref=f2e2]
    """)

    Page.evaluate!(page, "() => document.querySelector('iframe').remove()")

    assert_contain_yaml(snapshot_for_ai(page), """
      - list [ref=e2]:
        - listitem [ref=e3]
        - listitem [ref=e5]:
          - iframe [ref=e6]:
            - button "button2" [ref=f2e2]
    """)

    Expect.to_have_text!(Page.get_by_ref(page, "f2e2"), "button2")

    Page.evaluate!(page, """
    () => {
      const frame = document.createElement('iframe');
      frame.setAttribute('srcdoc', '<button>button1</button>');
      document.querySelector('li').appendChild(frame);
    }
    """)

    assert_contain_yaml(snapshot_for_ai(page), """
      - list [ref=e2]:
        - listitem [ref=e3]:
          - iframe [ref=e7]:
            - button "button1" [ref=f3e2]
        - listitem [ref=e5]:
          - iframe [ref=e6]:
            - button "button2" [ref=f2e2]
    """)

    Expect.to_have_text!(Page.get_by_ref(page, "f3e2"), "button1")
    Expect.to_have_text!(Page.get_by_ref(page, "f2e2"), "button2")
  end

  test "should not generate refs for elements with pointer-events:none", %{page: page} do
    Page.set_content!(page, """
      <button style="pointer-events: none">no-ref</button>
      <div style="pointer-events: none">
        <button style="pointer-events: auto">with-ref</button>
      </div>
      <div style="pointer-events: none">
        <div style="pointer-events: initial">
          <button>with-ref</button>
        </div>
      </div>
      <div style="pointer-events: none">
        <div style="pointer-events: auto">
          <button>with-ref</button>
        </div>
      </div>
      <div style="pointer-events: auto">
        <div style="pointer-events: none">
          <button>no-ref</button>
        </div>
      </div>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - button "no-ref"
        - button "with-ref" [ref=e2]
        - button "with-ref" [ref=e4]
        - button "with-ref" [ref=e6]
        - generic [ref=e7]:
          - generic:
            - button "no-ref"
    """)
  end

  test "emit generic roles for nodes w/o roles", %{page: page} do
    Page.set_content!(page, """
      <style>
      input {
        width: 0;
        height: 0;
        opacity: 0;
      }
      </style>
      <div>
        <label>
          <span>
            <input type="radio" value="Apple" checked="">
          </span>
          <span>Apple</span>
        </label>
        <label>
          <span>
            <input type="radio" value="Pear">
          </span>
          <span>Pear</span>
        </label>
        <label>
          <span>
            <input type="radio" value="Orange">
          </span>
          <span>Orange</span>
        </label>
      </div>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [ref=e2]:
        - generic [ref=e3]:
          - generic [ref=e4]:
            - radio "Apple" [checked]
          - text: Apple
        - generic [ref=e5]:
          - generic [ref=e6]:
            - radio "Pear"
          - text: Pear
        - generic [ref=e7]:
          - generic [ref=e8]:
            - radio "Orange"
          - text: Orange
    """)
  end

  test "should collapse generic nodes", %{page: page} do
    Page.set_content!(page, """
      <div>
        <div>
          <div>
            <button>Button</button>
          </div>
        </div>
      </div>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - button "Button" [ref=e5]
    """)
  end

  test "should include cursor pointer hint", %{page: page} do
    Page.set_content!(page, """
      <button style="cursor: pointer">Button</button>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - button "Button" [ref=e2] [cursor=pointer]
    """)
  end

  test "should not nest cursor pointer hints", %{page: page} do
    Page.set_content!(page, """
      <a style="cursor: pointer" href="about:blank">
        Link with a button
        <button style="cursor: pointer">Button</button>
      </a>
    """)

    snapshot = snapshot_for_ai(page)
    # The link's name is redundant - "Link with a button" prints as text and "Button" as the button -
    # so it is dropped even though the node is clickable.
    assert_contain_yaml(snapshot, """
      - link [ref=e2] [cursor=pointer]:
        - /url: about:blank
        - text: Link with a button
        - button "Button" [ref=e3]
    """)
  end

  test "should omit names that just repeat printed descendant nodes", %{page: page} do
    Page.set_content!(page, """
      <h3><a style="cursor: pointer" href="/issues/1">Clipboard API</a></h3>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - heading [level=3] [ref=e2]:
        - link "Clipboard API" [ref=e3] [cursor=pointer]:
          - /url: /issues/1
    """)
  end

  test "should omit redundant name when a contributing wrapper is collapsed", %{page: page} do
    # The flex span contributes to the heading's name, but is then removed from the tree as a
    # single-child generic wrapper. Its contribution is fully represented by the link, so the
    # heading's name is still redundant.
    Page.set_content!(page, """
      <h3><span style="display: flex"><a style="cursor: pointer" href="/issues/1">Clipboard API</a></span></h3>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - heading [level=3] [ref=e2]:
        - link "Clipboard API" [ref=e4] [cursor=pointer]:
          - /url: /issues/1
    """)
  end

  test "should omit redundant name when a contributor is a skipped leaf generic", %{page: page} do
    # The outer span is not collapsed (its child is an element, not text), so it becomes a leaf
    # generic node that contributes to both names. The link's rendered name covers it, which in turn
    # makes the heading's name redundant.
    Page.set_content!(page, """
      <h3><a style="cursor: pointer" href="/issues/1"><span><span>Clipboard API</span></span></a></h3>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - heading [level=3] [ref=e2]:
        - link "Clipboard API" [ref=e3] [cursor=pointer]:
          - /url: /issues/1
    """)
  end

  test "should keep the name when the contributing wrapper collapses into repeating text", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/41985
    # The outer span is marked as represented while it still wraps the icon. Once the nameless
    # image is dropped, the span collapses into a lone text repeating the button's name and removes
    # itself, so the button must keep the name derived from it.
    Page.set_content!(page, """
      <button>
        <span>
          <span>
            <svg focusable="false" tabindex="-1" aria-hidden="true" viewBox="0 0 448 512">
              <path d="M416 208H272V64c0-17.67-14.33-32-32-32h-32c-17.67 0-32 14.33-32 32v144H32c-17.67 0-32 14.33-32 32v32c0 17.67 14.33 32 32 32h144v144c0 17.67 14.33 32 32 32h32c17.67 0 32-14.33 32-32V304h144c17.67 0 32-14.33 32-32v-32c0-17.67-14.33-32-32-32z"/>
            </svg>
          </span>
          <span>Add New Item</span>
        </span>
      </button>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - button "Add New Item" [ref=e2]
    """)
  end

  test "should keep names not derived from printed nodes", %{page: page} do
    Page.set_content!(page, """
      <h3 aria-label="Clipboard API issue"><a style="cursor: pointer" href="/issues/1">Clipboard API</a></h3>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - heading "Clipboard API issue" [level=3] [ref=e2]:
        - link "Clipboard API" [ref=e3] [cursor=pointer]:
          - /url: /issues/1
    """)
  end

  test "should omit images without an accessible name", %{page: page} do
    Page.set_content!(page, """
      <img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=">
      <img alt="A cat" src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=">
      <img style="cursor: pointer" src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=">
    """)

    snapshot = snapshot_for_ai(page)
    # A nameless image that cannot be clicked carries no information and is omitted.
    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - img "A cat" [ref=e3]
        - img [ref=e4] [cursor=pointer]
    """)

    refute snapshot =~ "[ref=e2]"
  end

  test "should omit a nameless image nested inside a link", %{page: page} do
    # The decorative image has no name, so it is dropped even though it sits inside a clickable link.
    Page.set_content!(page, """
      <a style="cursor: pointer" href="/issue/1">Open issue <img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA="></a>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - link "Open issue" [ref=e2] [cursor=pointer]:
        - /url: /issue/1
    """)

    refute snapshot =~ "img"
  end

  test "should keep icon-only clickable elements", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/42013
    icon = ~s(<svg viewBox="0 0 1024 1024"><use xlink:href="#icon"></use></svg>)

    Page.set_content!(page, """
      <div style="cursor: pointer" aria-haspopup="true"><i>#{icon}</i></div>
      <img style="cursor: pointer" src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=">
      <a style="cursor: pointer" href="/target">#{icon}</a>
      <div onclick="void 0">#{icon}</div>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - generic [ref=e2] [cursor=pointer]
        - img [ref=e5] [cursor=pointer]
        - link [ref=e6] [cursor=pointer]:
          - /url: /target
    """)
  end

  test "should omit leaf generic whose text is already in an ancestor name", %{page: page} do
    # The inner element is block so it survives as its own generic node (an inline single-text span
    # would be collapsed into the link instead). It inherits the link's pointer cursor.
    Page.set_content!(page, """
      <a style="cursor: pointer" href="/issues/15860"><div>[Feature] a dedicated clipboard API</div></a>
    """)

    snapshot = snapshot_for_ai(page)
    # The link keeps its name, and the inner leaf generic that the name was computed from is dropped
    # because its text is already shown by the name.
    assert_contain_yaml(snapshot, """
      - link "[Feature] a dedicated clipboard API" [ref=e2] [cursor=pointer]:
        - /url: /issues/15860
    """)

    refute snapshot =~ "[ref=e3]"
  end

  test "should omit name-repeating generic behind a wrapper", %{page: page} do
    # The leaf generic that repeats the link's name sits inside a nameless wrapper. Its text is
    # first inlined into the wrapper, which then faces the link and removes itself.
    Page.set_content!(page, """
      <a style="cursor: pointer" href="/labels"><span style="display: inline-block"><span style="display: inline-block"><span>P3-collecting-feedback</span></span></span></a>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - link "P3-collecting-feedback" [ref=e2] [cursor=pointer]:
        - /url: /labels
    """)

    assert length(String.split(snapshot, "P3-collecting-feedback")) == 2
  end

  test "should resolve refs of distilled-away nodes", %{page: page} do
    Page.set_content!(page, """
      <a style="cursor: pointer" href="/issues/15860"><div>[Feature] a dedicated clipboard API</div></a>
    """)

    snapshot = snapshot_for_ai(page)
    # The inner leaf generic is distilled away, but its ref still resolves to the element.
    refute snapshot =~ "[ref=e3]"
    Expect.to_have_text!(Page.get_by_ref(page, "e3"), "[Feature] a dedicated clipboard API")
  end

  test "should not distill snapshots outside of ai mode", %{page: page} do
    Page.set_content!(page, """
      <h3><a href="/issues/1">Clipboard API</a></h3>
    """)

    # The heading name would be dropped as redundant in ai mode; matching mode keeps it.
    Expect.to_match_aria_snapshot!(Page.locator(page, "body"), """
      - heading "Clipboard API" [level=3]:
        - link "Clipboard API":
          - /url: /issues/1
    """)
  end

  test "should truncate data url in link", %{page: page} do
    base64 = Base.encode64("<p>hello</p>")
    Page.set_content!(page, ~s(<a href="data:text/html;base64,#{base64}">a link</a>))
    snapshot = snapshot_for_ai(page)
    assert snapshot =~ "/url: data:text/html;base64,…"
    refute snapshot =~ base64
  end

  test "should gracefully fallback when child frame cant be captured", %{page: page, server: server} do
    Page.set_content!(
      page,
      """
        <p>Test</p>
        <iframe src="#{server.prefix}/redirectloop1.html#depth=100000"></iframe>
      """,
      wait_until: :domcontentloaded
    )

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - paragraph [ref=e2]: Test
        - iframe [ref=e3]
    """)
  end

  test "should auto-wait for navigation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/frame.html")
    reload = Task.async(fn -> Page.evaluate!(page, "() => window.location.reload()") end)
    snapshot = Task.async(fn -> snapshot_for_ai(page) end)
    [_, snapshot] = Task.await_many([reload, snapshot], :infinity)
    # The snapshot races the reload, which may re-number the main frame, so accept any ref.
    assert snapshot =~ ~r/- generic \[active\] \[ref=(?:f\d+)?e\d+\]: Hi, I'm frame/
  end

  test "should auto-wait for blocking CSS", %{page: page, server: server} do
    TestServer.set_route(server, "/css", fn conn ->
      Process.sleep(1000)
      conn |> Plug.Conn.put_resp_header("content-type", "text/css") |> Plug.Conn.send_resp(200, "body { monospace }")
    end)

    Page.set_content!(
      page,
      """
        <script src="#{server.prefix}/css"></script>
        <p>Hello World</p>
      """,
      wait_until: :commit
    )

    assert_contain_yaml(snapshot_for_ai(page), "Hello World")
  end

  test "should show visible children of hidden elements", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/36296
    Page.set_content!(page, """
      <div style="visibility: hidden">
        <div style="visibility: visible">
          <button>Visible</button>
        </div>
        <div style="visibility: hidden">
          <button style="visibility: visible">Visible</button>
        </div>
        <div>
          <div style="visibility: visible">
            <button style="visibility: hidden">Hidden</button>
          </div>
          <button>Hidden</button>
        </div>
      </div>
    """)

    assert snapshot_for_ai(page) ==
             unshift("""
               - generic [active] [ref=e1]:
                 - button "Visible" [ref=e3]
                 - button "Visible" [ref=e4]
             """)
  end

  test "should include active element information", %{page: page} do
    Page.set_content!(page, """
      <button id="btn1">Button 1</button>
      <button id="btn2" autofocus>Button 2</button>
      <div>Not focusable</div>
    """)

    # Wait for autofocus to take effect
    Page.wait_for_function!(page, "() => document.activeElement?.id === 'btn2'")

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [ref=e1]:
        - button "Button 1" [ref=e2]
        - button "Button 2" [active] [ref=e3]
        - generic [ref=e4]: Not focusable
    """)
  end

  test "should update active element on focus", %{page: page} do
    Page.set_content!(page, """
      <input id="input1" placeholder="First input">
      <input id="input2" placeholder="Second input">
    """)

    # Initially there shouldn't be an active element on the inputs
    initial_snapshot = snapshot_for_ai(page)

    assert_contain_yaml(initial_snapshot, """
      - generic [active] [ref=e1]:
        - textbox "First input" [ref=e2]
        - textbox "Second input" [ref=e3]
    """)

    # Focus the second input
    Locator.focus!(Page.locator(page, "#input2"))

    # After focus, the second input should be active
    after_focus_snapshot = snapshot_for_ai(page)

    assert_contain_yaml(after_focus_snapshot, """
      - generic [ref=e1]:
        - textbox "First input" [ref=e2]
        - textbox "Second input" [active] [ref=e3]
    """)
  end

  test "should mark iframe as active when it contains focused element", %{page: page} do
    # Create a simple HTML file for the iframe
    Page.set_content!(page, """
      <input id="regular-input" placeholder="Regular input">
      <iframe src="data:text/html,<input id='iframe-input' placeholder='Input in iframe'>" tabindex="0"></iframe>
    """)

    # Test 1: Focus the input inside the iframe
    page |> Page.frame_locator("iframe") |> FrameLocator.locator("#iframe-input") |> Locator.focus!()
    input_in_iframe_focused_snapshot = snapshot_for_ai(page)

    # The iframe should be marked as active when it contains a focused element
    assert_contain_yaml(input_in_iframe_focused_snapshot, """
      - generic [ref=e1]:
        - textbox "Regular input" [ref=e2]
        - iframe [active] [ref=e3]:
          - textbox "Input in iframe" [active] [ref=f1e2]
    """)
  end

  test "return empty snapshot when iframe is not loaded", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/pull/36710
    Page.set_content!(page, """
      <div style="height: 5000px;">Test</div>
      <iframe loading="lazy" src="#{server.prefix}/frame.html"></iframe>
    """)

    # Wait for the iframe to load
    Page.wait_for_selector!(page, "iframe")

    # Get the snapshot of the page
    snapshot = snapshot_for_ai(page, timeout: 3000)

    # The iframe should be present but empty
    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - generic [ref=e2]: Test
        - iframe [ref=e3]
    """)
  end

  test "should support many properties on iframes", %{page: page} do
    Page.set_content!(page, """
      <input id="regular-input" placeholder="Regular input">
      <iframe style='cursor: pointer' src="data:text/html,<input id='iframe-input' placeholder='Input in iframe'/>" tabindex="0"></iframe>
    """)

    # Test 1: Focus the input inside the iframe
    page |> Page.frame_locator("iframe") |> FrameLocator.locator("#iframe-input") |> Locator.focus!()
    input_in_iframe_focused_snapshot = snapshot_for_ai(page)

    assert_contain_yaml(input_in_iframe_focused_snapshot, """
      - generic [ref=e1]:
        - textbox "Regular input" [ref=e2]
        - iframe [active] [ref=e3] [cursor=pointer]:
          - textbox "Input in iframe" [active] [ref=f1e2]
    """)
  end

  test "should snapshot frameset pages", %{page: page, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/41784
    html_route(
      server,
      "/frameset.html",
      ~s(<frameset rows="50%,50%"><frameset cols="50%,50%"><frame src="/frame-one.html"><frame src="/frame-two.html"></frameset><frame src="/frame-three.html"></frameset>)
    )

    for name <- ["one", "two", "three"] do
      html_route(server, "/frame-#{name}.html", "<button>Button #{name}</button>")
    end

    Page.goto!(page, server.prefix <> "/frameset.html")

    snapshot = snapshot_for_ai(page, timeout: 3000)

    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - generic [ref=e2]:
          - iframe [ref=e3]:
            - button "Button one" [ref=f1e2]
          - iframe [ref=e4]:
            - button "Button two" [ref=f2e2]
        - iframe [ref=e5]:
          - button "Button three" [ref=f3e2]
    """)

    Expect.to_have_text!(Page.get_by_ref(page, "f2e2"), "Button two")
  end

  test "should snapshot a locator inside a frameset frame", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/frameset.html")

    snapshot = page |> Page.frames() |> Enum.at(1) |> Frame.locator("body") |> Locator.aria_snapshot!(mode: "ai")

    assert_contain_yaml(snapshot, """
      - generic [ref=f1e1]: Hi, I'm frame
    """)

    Expect.to_have_text!(Page.get_by_ref(page, "f1e1"), "Hi, I'm frame")
    resolved = Locator.normalize!(Page.get_by_ref(page, "f1e1"))
    # Elixir syntax: the client renders locators (PLAN).
    assert Locator.to_string(resolved) ==
             ~s'Page.locator(page, "frame") |> Locator.first() |> Locator.content_frame() |> FrameLocator.locator("body")'
  end

  test "should stitch iframes inside a frameset frame", %{page: page, server: server} do
    html_route(server, "/frameset-with-iframe.html", ~s(<frameset><frame src="/frame-with-iframe.html"></frameset>))

    html_route(
      server,
      "/frame-with-iframe.html",
      ~s(<button>In frame</button><iframe srcdoc="<button>In iframe</button>"></iframe>)
    )

    Page.goto!(page, server.prefix <> "/frameset-with-iframe.html")

    assert_contain_yaml(snapshot_for_ai(page), """
      - iframe [ref=e2]:
        - generic [ref=f1e1]:
          - button "In frame" [ref=f1e2]
          - iframe [ref=f1e3]:
            - button "In iframe" [ref=f2e2]
    """)

    Expect.to_have_text!(Page.get_by_ref(page, "f1e2"), "In frame")
    Expect.to_have_text!(Page.get_by_ref(page, "f2e2"), "In iframe")

    resolved = Locator.normalize!(Page.get_by_ref(page, "f2e2"))

    # Elixir syntax: the client renders locators (PLAN).
    assert Locator.to_string(resolved) ==
             ~s'Page.locator(page, "frame") |> Locator.content_frame() |> FrameLocator.locator("iframe") |> Locator.content_frame() |> FrameLocator.get_by_role(:button, name: "In iframe")'
  end

  test "should stitch nested frameset documents", %{page: page, server: server} do
    html_route(server, "/outer-frameset.html", ~s(<frameset><frame src="/inner-frameset.html"></frameset>))
    html_route(server, "/inner-frameset.html", ~s(<frameset><frameset><frame src="/leaf.html"></frameset></frameset>))
    html_route(server, "/leaf.html", "<button>Leaf button</button>")
    Page.goto!(page, server.prefix <> "/outer-frameset.html")

    assert_contain_yaml(snapshot_for_ai(page), """
      - iframe [ref=e2]:
        - iframe [ref=f1e3]:
          - button "Leaf button" [ref=f2e2]
    """)

    Expect.to_have_text!(Page.get_by_ref(page, "f2e2"), "Leaf button")
  end

  test "should collapse inline generic nodes", %{page: page} do
    Page.set_content!(page, """
      <ul>
        <li><b>3</b> <abbr>bds</abbr></li>
        <li><b>2</b> <abbr>ba</abbr></li>
        <li><b>1,200</b> <abbr>sqft</abbr></li>
      </ul>
      <ul>
        <li><div>3</div></li>
        <li><div>2</div></li>
        <li><div>1,200</div></li>
      </ul>\
    """)

    snapshot1 = snapshot_for_ai(page)

    assert_contain_yaml(snapshot1, """
      - generic [active] [ref=e1]:
        - list [ref=e2]:
          - listitem [ref=e3]: 3 bds
          - listitem [ref=e4]: 2 ba
          - listitem [ref=e5]: 1,200 sqft
        - list [ref=e6]:
          - listitem [ref=e7]:
            - generic [ref=e8]: "3"
          - listitem [ref=e9]:
            - generic [ref=e10]: "2"
          - listitem [ref=e11]:
            - generic [ref=e12]: 1,200
    """)
  end

  test "should inline single leaf generic child into parent generic", %{page: page} do
    # The nameless images are distilled away, so each wrapper is left with a single leaf generic
    # child, whose text is inlined into the wrapper - recursively for the second one.
    Page.set_content!(page, """
      <div><img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA="><div>Status: Open.</div></div>
      <div><img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA="><div><img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA="><div>Nested twice.</div></div></div>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]:
        - generic [ref=e2]: "Status: Open."
        - generic [ref=e5]: Nested twice.
    """)
  end

  test "should inline a deeply nested generic", %{page: page} do
    # Every wrapper contains a nameless image (distilled away) plus a single generic child, so the
    # text bubbles up the whole chain - all the way into the body.
    img = ~s(<img src="data:image/gif;base64,R0lGODlhAQABAAAAACwAAAAAAQABAAA=">)

    Page.set_content!(page, """
      <div>#{img}<div>#{img}<div>#{img}<div>#{img}<div>Deeply nested.</div></div></div></div></div>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic [active] [ref=e1]: Deeply nested.
    """)

    refute snapshot =~ "img"
  end

  test "should not remove generic nodes with title", %{page: page} do
    Page.set_content!(page, ~s(<div title="Element title">Element content</div>))

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - generic "Element title" [ref=e2]
    """)
  end

  test "should limit depth", %{page: page} do
    Page.set_content!(page, """
      <ul>
        <li>item1</li>
        <a href="about:blank" style="cursor:pointer">link</a>
        <li>
          <ul id=target>
            <li>item2</li>
            <li>
              <ul>
                <li>item3</li>
              </ul>
            </li>
          </ul>
        </li>
      </ul>
    """)

    snapshot1 = snapshot_for_ai(page, depth: 1)

    assert_contain_yaml(snapshot1, """
      - list [ref=e2]:
        - listitem [ref=e3]: item1
        - link "link" [ref=e4] [cursor=pointer]:
          - /url: about:blank
        - listitem [ref=e5]
    """)

    snapshot2 = snapshot_for_ai(page, depth: 3)

    assert_contain_yaml(snapshot2, """
      - list [ref=e2]:
        - listitem [ref=e3]: item1
        - link "link" [ref=e4] [cursor=pointer]:
          - /url: about:blank
        - listitem [ref=e5]:
          - list [ref=e6]:
            - listitem [ref=e7]: item2
            - listitem [ref=e8]
    """)

    snapshot3 = snapshot_for_ai(page, depth: 100)

    assert_contain_yaml(snapshot3, """
      - list [ref=e2]:
        - listitem [ref=e3]: item1
        - link "link" [ref=e4] [cursor=pointer]:
          - /url: about:blank
        - listitem [ref=e5]:
          - list [ref=e6]:
            - listitem [ref=e7]: item2
            - listitem [ref=e8]:
              - list [ref=e9]:
                - listitem [ref=e10]: item3
    """)

    snapshot4 = Locator.aria_snapshot!(Page.locator(page, "#target"), mode: "ai", depth: 1)

    assert_contain_yaml(snapshot4, """
      - list [ref=e6]:
        - listitem [ref=e7]: item2
        - listitem [ref=e8]
    """)
  end

  test "should annotate aria-hidden elements", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/42223
    Page.set_content!(page, """
      <h2>Visible heading</h2>
      <div aria-hidden="true">
        <h1>Hidden heading</h1>
        <p>Hidden content</p>
      </div>
      <h2>After hidden</h2>
    """)

    assert_contain_yaml(snapshot_for_ai(page), """
      - generic [active] [ref=e1]:
        - heading "Visible heading" [level=2] [ref=e2]
        - generic [aria-hidden] [ref=e3]:
          - heading [level=1] [ref=e4]: Hidden heading
          - paragraph [ref=e5]: Hidden content
        - heading "After hidden" [level=2] [ref=e6]
    """)

    # Default snapshot excludes aria-hidden elements entirely.
    default_snapshot = Locator.aria_snapshot!(Page.locator(page, "body"))
    refute default_snapshot =~ "Hidden content"
  end

  test "should only annotate the top element in a hidden subtree", %{page: page} do
    # issue: https://github.com/microsoft/playwright/issues/42223
    Page.set_content!(page, """
      <div aria-hidden="true">
        <h1>Heading</h1>
        <p>Paragraph</p>
      </div>
    """)

    # Only the element with aria-hidden="true" gets the annotation, not its descendants.
    assert_contain_yaml(snapshot_for_ai(page), """
      - generic [aria-hidden] [ref=e2]:
        - heading [level=1] [ref=e3]: Heading
        - paragraph [ref=e4]: Paragraph
    """)
  end

  test "should not include hidden iframes", %{page: page} do
    Page.set_content!(page, """
      <iframe name="visible" srcdoc="<button>Visible</button>"></iframe>
      <iframe name="hidden" style="visibility: hidden" srcdoc="<button>Hidden</button>"></iframe>
      <iframe name="none" style="display: none" srcdoc="<button>None</button>"></iframe>
    """)

    snapshot = snapshot_for_ai(page)

    assert_contain_yaml(snapshot, """
      - iframe [ref=e2]:
        - button "Visible" [ref=f1e2]
    """)

    refute snapshot =~ "Hidden"
    refute snapshot =~ "None"
  end
end
