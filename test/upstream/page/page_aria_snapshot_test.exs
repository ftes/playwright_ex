defmodule PlaywrightEx.Page.PageAriaSnapshotTest do
  @upstream "tests/page/page-aria-snapshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  # tests/config/utils.ts
  defp unshift(snapshot) do
    lines = String.split(snapshot, "\n")

    prefix =
      for line <- lines, String.trim(line) != "", reduce: 100 do
        acc -> min(acc, byte_size(line) - byte_size(String.trim_leading(line)))
      end

    lines
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.map_join("\n", &binary_slice(&1, prefix..-1//1))
  end

  # expect(received).toContainYaml(expected), tests/page/pageTest.ts
  defp contains_yaml?(received, expected), do: String.contains?(received, unshift(expected))

  defp check_and_match_snapshot(locator, snapshot) do
    assert Locator.aria_snapshot!(locator) == unshift(snapshot)
    Expect.to_match_aria_snapshot!(locator, snapshot)
  end

  test "should snapshot", %{page: page} do
    Page.set_content!(page, "<h1>title</h1>")

    check_and_match_snapshot(Page.locator(page, "body"), """
    - heading "title" [level=1]
    """)
  end

  test "should snapshot list", %{page: page} do
    Page.set_content!(page, """
    <h1>title</h1>
    <h1>title 2</h1>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - heading "title" [level=1]
    - heading "title 2" [level=1]
    """)
  end

  test "should snapshot list with accessible name", %{page: page} do
    Page.set_content!(page, """
    <ul aria-label="my list">
      <li>one</li>
      <li>two</li>
    </ul>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - list "my list":
      - listitem: one
      - listitem: two
    """)
  end

  test "should quote names that look like regexes", %{page: page} do
    Page.set_content!(page, """
    <nav>
      <a href="/">/</a>
      <a href="/docs/">/docs/</a>
      <a href="/a(b/">/a(b/</a>
    </nav>
    """)

    check_and_match_snapshot(Page.locator(page, "nav"), """
    - navigation:
      - link "/":
        - /url: /
      - link "/docs/":
        - /url: /docs/
      - link "/a(b/":
        - /url: /a(b/
    """)
  end

  test "should snapshot complex", %{page: page} do
    Page.set_content!(page, """
    <ul>
      <li>
        <a href='about:blank'>link</a>
      </li>
    </ul>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - list:
      - listitem:
        - link "link":
          - /url: about:blank
    """)
  end

  test "should allow text nodes", %{page: page} do
    Page.set_content!(page, """
    <h1>Microsoft</h1>
    <div>Open source projects and samples from Microsoft</div>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - heading "Microsoft" [level=1]
    - text: Open source projects and samples from Microsoft
    """)
  end

  test "should snapshot details visibility", %{page: page} do
    Page.set_content!(page, """
    <details>
      <summary>Summary</summary>
      <div>Details</div>
    </details>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - group: Summary
    """)
  end

  test "should snapshot integration", %{page: page} do
    Page.set_content!(page, """
    <h1>Microsoft</h1>
    <div>Open source projects and samples from Microsoft</div>
    <ul>
      <li>
        <details>
          <summary>
            Verified
          </summary>
          <div>
            <div>
              <p>
                We've verified that the organization <strong>microsoft</strong> controls the domain:
              </p>
              <ul>
                <li class="mb-1">
                  <strong>opensource.microsoft.com</strong>
                </li>
              </ul>
              <div>
                <a href="about: blank">Learn more about verified organizations</a>
              </div>
            </div>
          </div>
        </details>
      </li>
      <li>
        <a href="about:blank">
          <summary title="Label: GitHub Sponsor">Sponsor</summary>
        </a>
      </li>
    </ul>\
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - heading "Microsoft" [level=1]
    - text: Open source projects and samples from Microsoft
    - list:
      - listitem:
        - group: Verified
      - listitem:
        - link "Sponsor":
          - /url: about:blank
    """)
  end

  test "should support multiline text", %{page: page} do
    Page.set_content!(page, """
    <p>
      Line 1
      Line 2
      Line 3
    </p>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - paragraph: Line 1 Line 2 Line 3
    """)

    Expect.to_match_aria_snapshot!(Page.locator(page, "body"), """
    - paragraph: |
          Line 1
          Line 2
          Line 3
    """)
  end

  test "should concatenate span text", %{page: page} do
    Page.set_content!(page, """
    <span>One</span> <span>Two</span> <span>Three</span>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - text: One Two Three
    """)
  end

  test "should concatenate span text 2", %{page: page} do
    Page.set_content!(page, """
    <span>One </span><span>Two </span><span>Three</span>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - text: One Two Three
    """)
  end

  test "should concatenate div text with spaces", %{page: page} do
    Page.set_content!(page, """
    <div>One</div><div>Two</div><div>Three</div>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - text: One Two Three
    """)
  end

  test "should include pseudo in text", %{page: page} do
    Page.set_content!(page, """
    <style>
      span:before {
        content: 'world';
      }
      div:after {
        content: 'bye';
      }
    </style>
    <a href="about:blank">
      <span>hello</span>
      <div>hello</div>
    </a>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "worldhello hellobye":
      - /url: about:blank
    """)
  end

  test "should not include hidden pseudo in text", %{page: page} do
    Page.set_content!(page, """
    <style>
      span:before {
        content: 'world';
        display: none;
      }
      div:after {
        content: 'bye';
        visibility: hidden;
      }
    </style>
    <a href="about:blank">
      <span>hello</span>
      <div>hello</div>
    </a>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "hello hello":
      - /url: about:blank
    """)
  end

  test "should include new line for block pseudo", %{page: page} do
    Page.set_content!(page, """
    <style>
      span:before {
        content: 'world';
        display: block;
      }
      div:after {
        content: 'bye';
        display: block;
      }
    </style>
    <a href="about:blank">
      <span>hello</span>
      <div>hello</div>
    </a>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "world hello hello bye":
      - /url: about:blank
    """)
  end

  test "should work with slots", %{page: page} do
    # Text "foo" is assigned to the slot, should not be used twice.
    Page.set_content!(page, """
    <button><div>foo</div></button>
    <script>
      (() => {
        const container = document.querySelector('div');
        const shadow = container.attachShadow({ mode: 'open' });
        const slot = document.createElement('slot');
        shadow.appendChild(slot);
      })();
    </script>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - button "foo"
    """)

    # Text "foo" is assigned to the slot, should be used instead of slot content.
    Page.set_content!(page, """
    <div>foo</div>
    <script>
      (() => {
        const container = document.querySelector('div');
        const shadow = container.attachShadow({ mode: 'open' });
        const button = document.createElement('button');
        shadow.appendChild(button);
        const slot = document.createElement('slot');
        button.appendChild(slot);
        const span = document.createElement('span');
        span.textContent = 'pre';
        slot.appendChild(span);
      })();
    </script>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - button "foo"
    """)

    # Nothing is assigned to the slot, should use slot content.
    Page.set_content!(page, """
    <div></div>
    <script>
      (() => {
        const container = document.querySelector('div');
        const shadow = container.attachShadow({ mode: 'open' });
        const button = document.createElement('button');
        shadow.appendChild(button);
        const slot = document.createElement('slot');
        button.appendChild(slot);
        const span = document.createElement('span');
        span.textContent = 'pre';
        slot.appendChild(span);
      })();
    </script>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - button "pre"
    """)
  end

  test "should snapshot inner text", %{page: page} do
    Page.set_content!(page, """
    <div role="listitem">
      <div>
        <div>
          <span title="a.test.ts">a.test.ts</span>
        </div>
        <div>
          <button title="Run"></button>
          <button title="Show source"></button>
          <button title="Watch"></button>
        </div>
      </div>
    </div>
    <div role="listitem">
      <div>
        <div>
          <span title="snapshot">snapshot</span>
        </div>
        <div class="ui-mode-list-item-time">30ms</div>
        <div>
          <button title="Run"></button>
          <button title="Show source"></button>
          <button title="Watch"></button>
        </div>
      </div>
    </div>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - listitem:
      - text: a.test.ts
      - button "Run"
      - button "Show source"
      - button "Watch"
    - listitem:
      - text: snapshot 30ms
      - button "Run"
      - button "Show source"
      - button "Watch"
    """)
  end

  test "should include pseudo codepoints", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <link href="codicon.css" rel="stylesheet" />
    <p class='codicon codicon-check'>hello</p>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - paragraph: hello
    """)
  end

  test "check aria-hidden text", %{page: page} do
    Page.set_content!(page, """
    <p>
      <span>hello</span>
      <span aria-hidden="true">world</span>
    </p>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - paragraph: hello
    """)
  end

  test "should ignore presentation and none roles", %{page: page} do
    Page.set_content!(page, """
    <ul>
      <li role='presentation'>hello</li>
      <li role='none'>world</li>
    </ul>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - list: hello world
    """)
  end

  test "should treat input value as text in templates, but not for checkbox/radio/file", %{page: page} do
    Page.set_content!(page, """
    <input value='hello world'>
    <input type=file>
    <input type=checkbox checked>
    <input type=radio checked>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - textbox: hello world
    - button "Choose File"
    - checkbox [checked]
    - radio [checked]
    """)
  end

  test "should not use on as checkbox value", %{page: page} do
    Page.set_content!(page, """
    <input type='checkbox'>
    <input type='radio'>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - checkbox
    - radio
    """)
  end

  test "should respect aria-owns", %{page: page} do
    Page.set_content!(page, """
    <a href='about:blank' aria-owns='input p'>
      <div role='region'>Link 1</div>
    </a>
    <a href='about:blank' aria-owns='input p'>
      <div role='region'>Link 2</div>
    </a>
    <input id='input' value='Value'>
    <p id='p'>Paragraph</p>
    """)

    # - Different from Chrome DevTools which attributes ownership to the last element.
    # - CDT also does not include non-owned children in accessible name.
    # - Disregarding these as aria-owns can't suggest multiple parts by spec.
    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "Link 1 Value Paragraph":
      - /url: about:blank
      - region: Link 1
      - textbox: Value
      - paragraph: Paragraph
    - link "Link 2 Value Paragraph":
      - /url: about:blank
      - region: Link 2
    """)
  end

  test "should be ok with circular ownership", %{page: page} do
    Page.set_content!(page, """
    <a href='about:blank' id='parent'>
      <div role='region' aria-owns='parent'>Hello</div>
    </a>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "Hello":
      - /url: about:blank
      - region: Hello
    """)
  end

  test "should escape yaml text in text nodes", %{page: page} do
    Page.set_content!(page, """
    <details>
      <summary>one: <a href="#">link1</a> "two <a href="#">link2</a> 'three <a href="#">link3</a> `four</summary>
    </details>
    <ul>
      <a href="#">one</a>,<a href="#">two</a>
      (<a href="#">three</a>)
      {<a href="#">four</a>}
      [<a href="#">five</a>]
    </ul>
    <div>[Select all]</div>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - group:
      - text: "one:"
      - link "link1":
        - /url: "#"
      - text: "\\\"two"
      - link "link2":
        - /url: "#"
      - text: "'three"
      - link "link3":
        - /url: "#"
      - text: "`four"
    - list:
      - link "one":
        - /url: "#"
      - text: ","
      - link "two":
        - /url: "#"
      - text: (
      - link "three":
        - /url: "#"
      - text: ") {"
      - link "four":
        - /url: "#"
      - text: "} ["
      - link "five":
        - /url: "#"
      - text: "]"
    - text: "[Select all]"
    """)
  end

  test "should normalize whitespace", %{page: page} do
    Page.set_content!(page, """
    <details>
      <summary> one  \n two <a href="#"> link &nbsp;\n  1 </a> </summary>
    </details>
    <input value='  hello   &nbsp; world '>
    <button>hello­​world</button>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - group:
      - text: one two
      - link "link 1":
        - /url: "#"
    - textbox: hello world
    - button "helloworld"
    """)

    # Weird whitespace in the template should be normalized.
    Expect.to_match_aria_snapshot!(Page.locator(page, "body"), """
    - group:
      - text: |
          one
          two
      - link "  link     1 ":
        - /url: "#"
    - textbox:        hello  world
    - button "he­lloworld​"
    """)
  end

  test "should handle long strings", %{page: page} do
    s = String.duplicate("a", 10_000)

    Page.set_content!(page, """
    <a href='about:blank'>
      <div role='region'>#{s}</div>
    </a>
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link:
      - /url: about:blank
      - region: #{s}
    """)
  end

  test "should escape special yaml characters", %{page: page} do
    Page.set_content!(page, """
    <a href="#">@hello</a>@hello
    <a href="#">]hello</a>]hello
    <a href="#">hello\n</a>
    hello\n<a href="#">\n hello</a>\n hello
    <a href="#">#hello</a>#hello
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "@hello":
      - /url: "#"
    - text: "@hello"
    - link "]hello":
      - /url: "#"
    - text: "]hello"
    - link "hello":
      - /url: "#"
    - text: hello
    - link "hello":
      - /url: "#"
    - text: hello
    - link "#hello":
      - /url: "#"
    - text: "#hello"
    """)
  end

  test "should escape special yaml values", %{page: page} do
    Page.set_content!(page, """
    <a href="#">true</a>False
    <a href="#">NO</a>yes
    <a href="#">y</a>N
    <a href="#">on</a>Off
    <a href="#">null</a>NULL
    <a href="#">123</a>123
    <a href="#">-1.2</a>-1.2
    <a href="#">-</a>-
    <input type=text value="555">
    """)

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "true":
      - /url: "#"
    - text: "False"
    - link "NO":
      - /url: "#"
    - text: "yes"
    - link "y":
      - /url: "#"
    - text: "N"
    - link "on":
      - /url: "#"
    - text: "Off"
    - link "null":
      - /url: "#"
    - text: "NULL"
    - link "123":
      - /url: "#"
    - text: "123"
    - link "-1.2":
      - /url: "#"
    - text: "-1.2"
    - link "-":
      - /url: "#"
    - text: "-"
    - textbox: "555"
    """)
  end

  test "should not report textarea textContent", %{page: page} do
    Page.set_content!(page, "<textarea>Before</textarea>")

    check_and_match_snapshot(Page.locator(page, "body"), """
    - textbox: Before
    """)

    Page.evaluate!(page, "() => { document.querySelector('textarea').value = 'After'; }")

    check_and_match_snapshot(Page.locator(page, "body"), """
    - textbox: After
    """)
  end

  test "should not show visible children of hidden elements", %{page: page} do
    Page.set_content!(page, """
    <div style="visibility: hidden;">
      <div style="visibility: visible;">
        <button>Button</button>
      </div>
    </div>
    """)

    assert Locator.aria_snapshot!(Page.locator(page, "body")) == ""
  end

  test "should not show unhidden children of aria-hidden elements", %{page: page} do
    Page.set_content!(page, """
    <div aria-hidden="true">
      <div aria-hidden="false">
        <button>Button</button>
      </div>
    </div>
    """)

    assert Locator.aria_snapshot!(Page.locator(page, "body")) == ""
  end

  test "should snapshot placeholder when different from the name", %{page: page} do
    Page.set_content!(page, """
    <input placeholder="Placeholder">
    """)

    assert contains_yaml?(Locator.aria_snapshot!(Page.locator(page, "body")), """
           - textbox "Placeholder"
           """)

    Page.set_content!(page, """
    <input placeholder="Placeholder" aria-label="Label">
    """)

    assert contains_yaml?(Locator.aria_snapshot!(Page.locator(page, "body")), """
           - textbox "Label":
             - /placeholder: Placeholder
           """)
  end

  test "match values both against regex and string", %{page: page} do
    Page.set_content!(page, ~s(<a href="/auth?r=/">Log in</a>))

    check_and_match_snapshot(Page.locator(page, "body"), """
    - link "Log in":
      - /url: /auth?r=/
    """)
  end

  test "auto-waits the locator and does not include iframes", %{page: page} do
    Page.set_content!(page, """
    <div>Hello</div>
    """)

    snapshot_promise = Task.async(fn -> Locator.aria_snapshot!(Page.locator(page, "#target")) end)
    Page.wait_for_timeout!(page, 2000)

    Page.set_content!(page, """
    <div id=target>
      Hello
      <iframe srcdoc="<ul><li>Item 1</li><li>Item 2</li></ul>"></iframe>
    </div>
    """)

    assert contains_yaml?(Task.await(snapshot_promise, :infinity), """
           - text: Hello
           """)
  end

  test "should limit depth", %{page: page} do
    Page.set_content!(page, """
    <ul id=target>
      <li>item2</li>
      <li>
        <ul>
          <li>item3</li>
        </ul>
      </li>
    </ul>
    """)

    snapshot = Locator.aria_snapshot!(Page.locator(page, "#target"), depth: 1)

    assert contains_yaml?(snapshot, """
           - list:
             - listitem: item2
             - listitem
           """)
  end

  test "should snapshot a locator inside an iframe", %{page: page} do
    Page.set_content!(page, """
    <h1>Main Page</h1>
    <iframe srcdoc="<ul><li>Item 1</li><li>Item 2</li></ul>"></iframe>
    """)

    list = page |> Page.frames() |> Enum.at(1) |> Frame.locator("ul")
    snapshot = Locator.aria_snapshot!(list)

    assert contains_yaml?(snapshot, """
           - list:
             - listitem: Item 1
             - listitem: Item 2
           """)
  end

  test "should include frames on frameset pages", %{page: page, server: server} do
    TestServer.set_route(server, "/frameset.html", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(
        200,
        ~s(<frameset cols="50%,50%"><frame src="/frames/frame.html"><frame src="/frames/frame.html"></frameset>)
      )
    end)

    Page.goto!(page, server.prefix <> "/frameset.html")
    # Like iframes, frames are listed in the snapshot, but their content is not included.
    assert Page.aria_snapshot!(page, timeout: 3000) ==
             unshift("""
             - iframe
             - iframe
             """)
  end

  test "should snapshot a locator inside a frameset frame", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/frameset.html")

    check_and_match_snapshot(
      page |> Page.frame_locator("frame") |> FrameLocator.first() |> FrameLocator.locator("body"),
      """
      - text: Hi, I'm frame
      """
    )
  end

  test "should snapshot with box from page", %{page: page} do
    Page.set_content!(page, """
    <button style="position:absolute;left:100px;top:50px;width:80px;height:40px;margin:0;padding:0;border:0;">click</button>
    """)

    snapshot = Page.aria_snapshot!(page, boxes: true)
    assert snapshot == ~s(- button "click" [box=100,50,80,40])
  end

  test "should snapshot with box from locator", %{page: page} do
    Page.set_content!(page, """
    <div style="position:absolute;left:10px;top:20px;width:200px;height:100px;">
      <button style="position:absolute;left:5px;top:5px;width:60px;height:30px;margin:0;padding:0;border:0;">ok</button>
    </div>
    """)

    snapshot = Locator.aria_snapshot!(Page.locator(page, "div"), boxes: true)
    assert snapshot == ~s(- button "ok" [box=15,25,60,30])
  end

  test "should not include box when option is omitted", %{page: page} do
    Page.set_content!(page, "<button>click</button>")
    snapshot = Page.aria_snapshot!(page)
    refute snapshot =~ ~r/\[box=/
  end

  test "should not include hidden iframes", %{page: page} do
    Page.set_content!(page, """
    <iframe name="visible" srcdoc="<button>Visible</button>"></iframe>
    <iframe name="hidden" style="visibility: hidden" srcdoc="<button>Hidden</button>"></iframe>
    <iframe name="none" style="display: none" srcdoc="<button>None</button>"></iframe>
    """)

    assert Page.aria_snapshot!(page) ==
             unshift("""
             - iframe
             """)
  end
end
