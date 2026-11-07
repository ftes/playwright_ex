defmodule PlaywrightEx.Page.PageClickTest do
  @upstream "tests/page/page-click.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import PlaywrightEx.Utils, only: [attach_frame: 3, rafraf: 2, rafraf: 1]

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  @moduletag :page

  defp give_it_a_chance_to_click(page), do: rafraf(page, 5)

  # `const p = action().then(() => done = true)`: `done?(task)` tells whether it has settled.
  defp done?(promise), do: Runtime.Promise.settled?(promise)

  # `expect.poll(fun).toEqual(expected)`: the last value of `fun`, polled until it equals `expected`.
  defp poll(fun, expected, tries \\ 100) do
    value = fun.()

    cond do
      value == expected -> value
      tries == 0 -> value
      true -> Process.sleep(100) && poll(fun, expected, tries - 1)
    end
  end

  # `const messages = []; page.on('console', msg => messages.push(msg.text()))`
  defp collect_console(page) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    Page.on(page, :console, fn msg -> Agent.update(agent, &(&1 ++ [ConsoleMessage.text(msg)])) end)
    fn -> Agent.get(agent, & &1) end
  end

  test "CL-001 should click the button @smoke", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-002 should click button inside frameset", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/frameset.html")
    frame_element = Page.query_selector!(page, "frame")
    JSHandle.evaluate!(frame_element, "frame => frame.src = '/input/button.html'")
    frame = ElementHandle.content_frame!(frame_element)
    Frame.click!(frame, "button")
    assert Frame.evaluate!(frame, "result") == "Clicked"
  end

  test "CL-003 should issue clicks in parallel in page and popup", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/counter.html")
    popup = Page.wait_for_event(page, :popup)
    Page.evaluate!(page, "() => window.open('/counter.html')")
    popup = Promise.await!(popup)

    click_promises =
      for i <- 0..20 do
        target = if rem(i, 3) == 0, do: popup, else: page
        Task.async(fn -> Locator.click!(Page.locator(target, "button")) end)
      end

    Task.await_many(click_promises, :infinity)
    assert Page.evaluate!(page, "() => window['count']") == 14
    assert Page.evaluate!(popup, "() => window['count']") == 7
  end

  test "CL-004 should click svg", %{page: page} do
    Page.set_content!(page, """
      <svg height="100" width="100">
        <circle onclick="window.__CLICKED=42" cx="50" cy="50" r="40" stroke="black" stroke-width="3" fill="red" />
      </svg>
    """)

    Page.click!(page, "circle")
    assert Page.evaluate!(page, "__CLICKED") == 42
  end

  test "CL-005 should click the button if window.Node is removed", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.evaluate!(page, "() => delete window.Node")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  # @see https://github.com/GoogleChrome/puppeteer/issues/4281
  test "CL-006 should click on a span with an inline element inside", %{page: page} do
    Page.set_content!(page, """
      <style>
      span::before {
        content: 'q';
      }
      </style>
      <span onclick='window.CLICKED=42'></span>
    """)

    Page.click!(page, "span")
    assert Page.evaluate!(page, "CLICKED") == 42
  end

  test "CL-007 should click the aligned 1x1 div", %{page: page} do
    Page.set_content!(page, ~s(<div style="width: 1px; height: 1px;" onclick="window.__clicked = true"></div>))
    Page.click!(page, "div")
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "CL-008 should click the half-aligned 1x1 div", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div style="margin-left: 20.5px; margin-top: 11.5px; width: 1px; height: 1px;" onclick="window.__clicked = true"></div>)
    )

    Page.click!(page, "div")
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "CL-009 should click the unaligned 1x1 div v1", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div style="margin-left: 20.23px; margin-top: 11.65px; width: 1px; height: 1px;" onclick="window.__clicked = true"></div>)
    )

    Page.click!(page, "div")
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "CL-010 should click the unaligned 1x1 div v2", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div style="margin-left: 20.68px; margin-top: 11.13px; width: 1px; height: 1px;" onclick="window.__clicked = true"></div>)
    )

    Page.click!(page, "div")
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "CL-011 should click the unaligned 1x1 div v3", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div style="margin-left: 20.68px; margin-top: 11.52px; width: 1px; height: 1px;" onclick="window.__clicked = true"></div>)
    )

    Page.click!(page, "div")
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "CL-012 should click the unaligned 1x1 div v4", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div style="margin-left: 20.15px; margin-top: 11.24px; width: 1px; height: 1px;" onclick="window.__clicked = true"></div>)
    )

    Page.click!(page, "div")
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "CL-013 should click the button after navigation ", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-014 should click the button after a cross origin navigation ", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    Page.goto!(page, server.cross_process_prefix <> "/input/button.html")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-015 should click when one of inline box children is outside of viewport", %{page: page} do
    Page.set_content!(page, """
      <style>
      i {
        position: absolute;
        top: -1000px;
      }
      </style>
      <span onclick='window.CLICKED = 42;'><i>woof</i><b>doggo</b></span>
    """)

    Page.click!(page, "span")
    assert Page.evaluate!(page, "CLICKED") == 42
  end

  test "CL-016 should select the text by triple clicking", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    text = "This is the text that we are going to try to select. Let's see how it goes."
    Page.fill!(page, "textarea", text)
    Page.click!(page, "textarea", click_count: 3)

    assert Page.evaluate!(page, """
           () => {
             const textarea = document.querySelector('textarea');
             return textarea.value.substring(textarea.selectionStart, textarea.selectionEnd);
           }
           """) == text
  end

  test "CL-017 should click offscreen buttons", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/offscreenbuttons.html")
    messages = collect_console(page)

    for i <- 0..10 do
      # We might've scrolled to click a button - reset to (0, 0).
      Page.evaluate!(page, "() => window.scrollTo(0, 0)")
      Page.click!(page, "#btn#{i}")
    end

    assert messages.() == for(i <- 0..10, do: "button ##{i} clicked")
  end

  test "CL-018 should waitFor visible when already visible", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-019 should not wait with force", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "b => b.style.display = 'none'")
    {:error, error} = Page.click(page, "button", force: true)
    assert Exception.message(error) =~ "Element is not visible"
    assert Page.evaluate!(page, "result") == "Was not clicked"
  end

  test "CL-020 should waitFor display:none to be gone", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "b => b.style.display = 'none'")
    clicked = Runtime.Promise.async(fn -> Page.click!(page, "button", timeout: 0) end, shared: true)
    give_it_a_chance_to_click(page)
    assert Page.evaluate!(page, "result") == "Was not clicked"
    refute done?(clicked)
    Page.eval_on_selector!(page, "button", "b => b.style.display = 'block'")
    Runtime.Promise.await(clicked)
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-021 should waitFor visibility:hidden to be gone", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "b => b.style.visibility = 'hidden'")
    clicked = Runtime.Promise.async(fn -> Page.click!(page, "button", timeout: 0) end, shared: true)
    give_it_a_chance_to_click(page)
    assert Page.evaluate!(page, "result") == "Was not clicked"
    refute done?(clicked)
    Page.eval_on_selector!(page, "button", "b => b.style.visibility = 'visible'")
    Runtime.Promise.await(clicked)
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-022 should waitFor visible when parent is hidden", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "b => b.parentElement.style.display = 'none'")
    clicked = Runtime.Promise.async(fn -> Page.click!(page, "button", timeout: 0) end, shared: true)
    give_it_a_chance_to_click(page)
    refute done?(clicked)
    Page.eval_on_selector!(page, "button", "b => b.parentElement.style.display = 'block'")
    Runtime.Promise.await(clicked)
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-023 should click wrapped links", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/wrappedlink.html")
    Page.click!(page, "a")
    assert Page.evaluate!(page, "__clicked") == true
  end

  test "CL-024 should click on checkbox input and toggle", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/checkbox.html")
    assert Page.evaluate!(page, "() => window['result'].check") == :null
    Page.click!(page, "input#agree")
    assert Page.evaluate!(page, "() => window['result'].check") == true
    # if (!headless) events = events.filter(...)  -- we run headless
    assert Page.evaluate!(page, "() => window['result'].events") == [
             "mouseover",
             "mouseenter",
             "mousemove",
             "mousedown",
             "mouseup",
             "click",
             "input",
             "change"
           ]

    Page.click!(page, "input#agree")
    assert Page.evaluate!(page, "() => window['result'].check") == false
  end

  test "CL-025 should click on checkbox label and toggle", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/checkbox.html")
    assert Page.evaluate!(page, "() => window['result'].check") == :null
    Page.click!(page, ~s(label[for="agree"]))
    assert Page.evaluate!(page, "() => window['result'].check") == true
    assert Page.evaluate!(page, "() => window['result'].events") == ["click", "input", "change"]
    Page.click!(page, ~s(label[for="agree"]))
    assert Page.evaluate!(page, "() => window['result'].check") == false
  end

  test "CL-026 should scroll and click the button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.click!(page, "#button-5")
    assert Page.evaluate!(page, "() => document.querySelector('#button-5').textContent") == "clicked"
    Page.click!(page, "#button-80")
    assert Page.evaluate!(page, "() => document.querySelector('#button-80').textContent") == "clicked"
  end

  test "CL-027 should scroll and click the button with smooth scroll behavior", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/12370' });
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.add_style_tag!(page, content: "html { scroll-behavior: smooth; }")

    for _ <- 1..5 do
      Page.click!(page, "#button-80")
      assert Page.evaluate!(page, "() => document.querySelector('#button-80').textContent") == "clicked"
      Page.click!(page, "#button-20")
      assert Page.evaluate!(page, "() => document.querySelector('#button-20').textContent") == "clicked"
    end
  end

  test "CL-028 should double click the button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.evaluate!(page, """
    () => {
      window['double'] = false;
      const button = document.querySelector('button');
      button.addEventListener('dblclick', event => {
        window['double'] = true;
      });
    }
    """)

    Page.dblclick!(page, "button")
    assert Page.evaluate!(page, "double") == true
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-029 should click a partially obscured button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.evaluate!(page, """
    () => {
      const button = document.querySelector('button');
      button.textContent = 'Some really long text that will go offscreen';
      button.style.position = 'absolute';
      button.style.left = '368px';
    }
    """)

    Page.click!(page, "button")
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "CL-030 should click a rotated button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/rotatedButton.html")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-031 should fire contextmenu event on right click", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.click!(page, "#button-8", button: :right)
    assert Page.evaluate!(page, "() => document.querySelector('#button-8').textContent") == "context menu"
  end

  test "CL-032 should click links which cause navigation", %{page: page, server: server} do
    # @see https://github.com/GoogleChrome/puppeteer/issues/206
    Page.set_content!(page, ~s(<a href="#{server.empty_page}">empty.html</a>))
    # This await should not hang.
    Page.click!(page, "a")
  end

  test "CL-033 should not wait for navigation after clicking a link answered with 204", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/43279' }
    TestServer.set_route(server, "/204", fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<a href="#{server.prefix}/204">link</a>))
    Page.click!(page, "a", timeout: 5000)
    assert Page.url(page) == server.empty_page
  end

  test "CL-034 should click the button inside an iframe", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, ~s(<div style="width:100px;height:100px">spacer</div>))
    attach_frame(page, "button-test", server.prefix <> "/input/button.html")
    frame = Enum.at(Page.frames(page), 1)
    button = Frame.query_selector!(frame, "button")
    ElementHandle.click!(button)
    assert Frame.evaluate!(frame, "() => window['result']") == "Clicked"
  end

  @tag skip: if(@browser_name == "chromium", do: "upstream fixme: chromium")
  test "CL-035 should click the button with fixed position inside an iframe",
       %{page: page, server: server} do
    # it.fixme(browserName === 'chromium');
    # @see https://github.com/GoogleChrome/puppeteer/issues/4110
    # @see https://bugs.chromium.org/p/chromium/issues/detail?id=986390
    # @see https://chromium-review.googlesource.com/c/chromium/src/+/1742784
    Page.goto!(page, server.empty_page)
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.set_content!(page, ~s(<div style="width:100px;height:2000px">spacer</div>))
    attach_frame(page, "button-test", server.cross_process_prefix <> "/input/button.html")
    frame = Enum.at(Page.frames(page), 1)
    Frame.eval_on_selector!(frame, "button", "button => button.style.setProperty('position', 'fixed')")
    Frame.click!(frame, "button")
    assert Frame.evaluate!(frame, "() => window['result']") == "Clicked"
  end

  test "CL-036 should click the button behind sticky header", %{page: page} do
    Page.set_viewport_size!(page, %{width: 500, height: 240})

    Page.set_content!(page, """
      <style>
      * {
        padding: 0;
        margin: 0;
      }
      li {
        height: 80px;
        border: 1px solid black;
      }
      ol {
        padding-top: 160px;
      }
      div.fixed {
        position: fixed;
        z-index: 1001;
        width: 100%;
        background: red;
        height: 160px;
      }
      </style>

      <div class=fixed></div>

      <ol>
      <li>hi1</li><li>hi2</li><li>hi3</li><li>hi4</li><li>hi5</li><li>hi6</li><li>hi7</li><li>hi8</li>
      <li id=target onclick="window.__clicked = true">hi9</li>
      <li>hi10</li><li>hi11</li><li>hi12</li><li>hi13</li><li id=li14>hi14</li>
      </ol>
    """)

    Page.eval_on_selector!(page, "#li14", "e => e.scrollIntoView()")
    Page.click!(page, "#target")
    assert Page.evaluate!(page, "() => window['__clicked']") == true
  end

  test "CL-037 should click the button behind position:absolute header", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/36339' }
    Page.set_viewport_size!(page, %{width: 500, height: 240})

    Page.set_content!(page, """
      <style>
      * {
        padding: 0;
        margin: 0;
      }
      li {
        height: 80px;
        border: 1px solid black;
      }
      ol {
        height: 100vh;
        overflow: scroll;
        padding-top: 160px;
      }
      body {
        position: relative;
      }
      div.fixed {
        position: absolute;
        top: 0;
        z-index: 1001;
        width: 100%;
        background: red;
        height: 160px;
      }
      </style>

      <ol>
      <li>hi1</li><li>hi2</li><li>hi3</li><li>hi4</li><li>hi5</li><li>hi6</li><li>hi7</li><li>hi8</li>
      <li id=target onclick="window.__clicked = true">hi9</li>
      <li>hi10</li><li>hi11</li><li>hi12</li><li>hi13</li><li id=li14>hi14</li>
      </ol>

      <div class=fixed>Overlay</div>
    """)

    Page.eval_on_selector!(page, "ol", """
    e => {
      const target = document.querySelector('#target');
      e.scrollTo({ top: target.offsetTop, behavior: 'instant' });
    }
    """)

    Page.click!(page, "#target")
    assert Page.evaluate!(page, "() => window['__clicked']") == true
  end

  test "CL-038 should click the button with px border with offset", %{page: page, server: server} do
    # it.skip(isFrozenWebkit, 'needs recent webkit');
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "button => button.style.borderWidth = '8px'")
    Page.click!(page, "button", position: %{x: 20, y: 10})
    assert Page.evaluate!(page, "result") == "Clicked"
    # Safari reports border-relative offsetX/offsetY.
    assert Page.evaluate!(page, "offsetX") == 20
    assert Page.evaluate!(page, "offsetY") == 10
  end

  test "CL-039 should click the button with em border with offset", %{page: page, server: server} do
    # it.skip(isFrozenWebkit, 'needs recent webkit');
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "button => button.style.borderWidth = '2em'")
    Page.eval_on_selector!(page, "button", "button => button.style.fontSize = '12px'")
    Page.click!(page, "button", position: %{x: 20, y: 10})
    assert Page.evaluate!(page, "result") == "Clicked"
    # Safari reports border-relative offsetX/offsetY.
    assert Page.evaluate!(page, "offsetX") == 20
    assert Page.evaluate!(page, "offsetY") == 10
  end

  test "CL-040 should click a very large button with offset", %{page: page, server: server} do
    # it.fixme(isAndroid, ...), it.skip(isFrozenWebkit, 'needs recent webkit');
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "button => button.style.borderWidth = '8px'")
    Page.eval_on_selector!(page, "button", "button => button.style.height = button.style.width = '2000px'")
    Page.click!(page, "button", position: %{x: 1900, y: 1910})
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
    # Safari reports border-relative offsetX/offsetY.
    assert Page.evaluate!(page, "offsetX") == 1900
    assert Page.evaluate!(page, "offsetY") == 1910
  end

  test "CL-041 should click a button in scrolling container with offset", %{page: page, server: server} do
    # it.fixme(isAndroid, ...), it.skip(isFrozenWebkit, 'needs recent webkit');
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.eval_on_selector!(page, "button", """
    button => {
      const container = document.createElement('div');
      container.style.overflow = 'auto';
      container.style.width = '200px';
      container.style.height = '200px';
      button.parentElement.insertBefore(container, button);
      container.appendChild(button);
      button.style.height = '2000px';
      button.style.width = '2000px';
      button.style.borderWidth = '8px';
    }
    """)

    Page.click!(page, "button", position: %{x: 1900, y: 1910})
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
    # Safari reports border-relative offsetX/offsetY.
    assert Page.evaluate!(page, "offsetX") == 1900
    assert Page.evaluate!(page, "offsetY") == 1910
  end

  test "CL-042 should wait for stable position", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.eval_on_selector!(page, "button", """
    button => {
      button.style.transition = 'margin 500ms linear 0s';
      button.style.marginLeft = '200px';
      button.style.borderWidth = '0';
      button.style.width = '200px';
      button.style.height = '20px';
      // Set display to "block" - otherwise Firefox layouts with non-even
      // values on Linux.
      button.style.display = 'block';
      document.body.style.margin = '0';
    }
    """)

    # rafraf for Firefox to kick in the animation.
    rafraf(page)
    Page.click!(page, "button")
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
    assert Page.evaluate!(page, "pageX") == 300
    assert Page.evaluate!(page, "pageY") == 10
  end

  @fly_over """
  button => {
    button.style.borderWidth = '0';
    button.style.width = '200px';
    button.style.height = '20px';
    document.body.style.margin = '0';
    document.body.style.position = 'relative';
    const flyOver = document.createElement('div');
    flyOver.className = 'flyover';
    flyOver.style.position = 'absolute';
    flyOver.style.width = '400px';
    flyOver.style.height = '20px';
    flyOver.style.left = '-200px';
    flyOver.style.top = '0';
    flyOver.style.background = 'red';
    document.body.appendChild(flyOver);
  }
  """

  test "CL-043 should wait for becoming hit target", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", @fly_over)
    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "button") end, shared: true)
    refute done?(click_promise)

    Page.eval_on_selector!(page, ".flyover", "flyOver => flyOver.style.left = '0'")
    give_it_a_chance_to_click(page)
    refute done?(click_promise)

    Page.eval_on_selector!(page, ".flyover", "flyOver => flyOver.style.left = '200px'")
    Runtime.Promise.await(click_promise)
    assert Page.evaluate!(page, "() => window['result']") == "Clicked"
  end

  test "CL-044 should wait for becoming hit target with trial run", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", @fly_over)
    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "button", trial: true) end, shared: true)
    refute done?(click_promise)

    Page.eval_on_selector!(page, ".flyover", "flyOver => flyOver.style.left = '0'")
    give_it_a_chance_to_click(page)
    refute done?(click_promise)

    Page.eval_on_selector!(page, ".flyover", "flyOver => flyOver.style.left = '200px'")
    Runtime.Promise.await(click_promise)

    # Should not actually click.
    assert Page.evaluate!(page, "() => window['result']") == "Was not clicked"
  end

  test "CL-045 trial run should work with short timeout", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.eval_on_selector!(page, "button", "button => button.disabled = true")
    {:error, error} = Page.click(page, "button", trial: true, timeout: 2000)
    assert Exception.message(error) =~ "click action (trial run)"
    assert Page.evaluate!(page, "() => window['result']") == "Was not clicked"
  end

  test "CL-046 trial run should not click", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button", trial: true)
    assert Page.evaluate!(page, "() => window['result']") == "Was not clicked"
  end

  test "CL-047 trial run should not double click", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.evaluate!(page, """
    () => {
      window['double'] = false;
      const button = document.querySelector('button');
      button.addEventListener('dblclick', event => {
        window['double'] = true;
      });
    }
    """)

    Page.dblclick!(page, "button", trial: true)
    assert Page.evaluate!(page, "double") == false
    assert Page.evaluate!(page, "result") == "Was not clicked"
  end

  test "CL-048 should fail when obscured and not waiting for hit target", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    button = Page.query_selector!(page, "button")

    Page.evaluate!(page, """
    () => {
      document.body.style.position = 'relative';
      const blocker = document.createElement('div');
      blocker.style.position = 'absolute';
      blocker.style.width = '400px';
      blocker.style.height = '20px';
      blocker.style.left = '0';
      blocker.style.top = '0';
      document.body.appendChild(blocker);
    }
    """)

    ElementHandle.click!(button, force: true)
    assert Page.evaluate!(page, "() => window['result']") == "Was not clicked"
  end

  test "CL-049 should wait for button to be enabled", %{page: page} do
    Page.set_content!(page, ~s(<button onclick="window.__CLICKED=true;" disabled><span>Click target</span></button>))
    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "text=Click target") end, shared: true)
    give_it_a_chance_to_click(page)
    assert Page.evaluate!(page, "window.__CLICKED") == nil
    refute done?(click_promise)
    Page.evaluate!(page, "() => document.querySelector('button').removeAttribute('disabled')")
    Runtime.Promise.await(click_promise)
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-050 should wait for element to become non-inert", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div inert id=container><button onclick="window.__CLICKED=true;"><span>Click target</span></button></div>)
    )

    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "text=Click target") end, shared: true)
    give_it_a_chance_to_click(page)
    assert Page.evaluate!(page, "window.__CLICKED") == nil
    refute done?(click_promise)
    Page.evaluate!(page, "() => document.getElementById('container').removeAttribute('inert')")
    Runtime.Promise.await(click_promise)
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-052 should wait for input to be enabled", %{page: page} do
    Page.set_content!(page, ~s(<input onclick="window.__CLICKED=true;" disabled>))
    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "input") end, shared: true)
    give_it_a_chance_to_click(page)
    assert Page.evaluate!(page, "window.__CLICKED") == nil
    refute done?(click_promise)
    Page.evaluate!(page, "() => document.querySelector('input').removeAttribute('disabled')")
    Runtime.Promise.await(click_promise)
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-053 should wait for select to be enabled", %{page: page} do
    Page.set_content!(page, """
      <select disabled><option selected>Hello</option></select>
      <script>
        document.querySelector('select').addEventListener('mousedown', event => {
          window.__CLICKED=true;
          event.preventDefault();
        });
      </script>
    """)

    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "select") end, shared: true)
    give_it_a_chance_to_click(page)
    assert Page.evaluate!(page, "window.__CLICKED") == nil
    refute done?(click_promise)
    Page.evaluate!(page, "() => document.querySelector('select').removeAttribute('disabled')")
    Runtime.Promise.await(click_promise)
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-054 should click disabled div", %{page: page} do
    Page.set_content!(page, ~s(<div onclick="window.__CLICKED=true" disabled>Click target</div>))
    Page.click!(page, "text=Click target")
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-055 should wait for BUTTON to be clickable when it has pointer-events:none", %{page: page} do
    Page.set_content!(
      page,
      ~s(<button onclick="window.__CLICKED=true" style="pointer-events:none"><span>Click target</span></button>)
    )

    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "text=Click target") end, shared: true)
    give_it_a_chance_to_click(page)
    assert Page.evaluate!(page, "window.__CLICKED") == nil
    refute done?(click_promise)
    Page.evaluate!(page, "() => document.querySelector('button').style.removeProperty('pointer-events')")
    Runtime.Promise.await(click_promise)
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-056 should wait for LABEL to be clickable when it has pointer-events:none", %{page: page} do
    Page.set_content!(
      page,
      ~s(<label onclick="window.__CLICKED=true" style="pointer-events:none"><span>Click target</span></label>)
    )

    click_promise = Runtime.Promise.async(fn -> Page.click!(page, "text=Click target") end)
    # Do a few roundtrips to the page.
    for _ <- 1..5, do: assert(Page.evaluate!(page, "window.__CLICKED") == nil)
    # remove `pointer-events: none` css from button.
    Page.evaluate!(page, "() => document.querySelector('label').style.removeProperty('pointer-events')")
    Runtime.Promise.await(click_promise)
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-057 should update modifiers correctly", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button", modifiers: [:shift])
    assert Page.evaluate!(page, "shiftKey") == true
    Page.click!(page, "button", modifiers: [])
    assert Page.evaluate!(page, "shiftKey") == false

    Keyboard.down!(Page.keyboard(page), "Shift")
    Page.click!(page, "button", modifiers: [])
    assert Page.evaluate!(page, "shiftKey") == false
    Page.click!(page, "button")
    assert Page.evaluate!(page, "shiftKey") == true
    Keyboard.up!(Page.keyboard(page), "Shift")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "shiftKey") == false
  end

  test "CL-058 should click an offscreen element when scroll-behavior is smooth", %{page: page} do
    Page.set_content!(page, """
      <div style="border: 1px solid black; height: 500px; overflow: auto; width: 500px; scroll-behavior: smooth">
      <button style="margin-top: 2000px" onClick="window.clicked = true">hi</button>
      </div>
    """)

    Page.click!(page, "button")
    assert Page.evaluate!(page, "window.clicked") == true
  end

  test "CL-059 should report nice error when element is detached and force-clicked", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/animating-button.html")
    Page.evaluate!(page, "addButton()")
    handle = Page.query_selector!(page, "button")
    Page.evaluate!(page, "stopButton(true)")
    {:error, error} = ElementHandle.click(handle, force: true)
    assert Page.evaluate!(page, "window.clicked") == nil
    assert Exception.message(error) =~ "Element is not attached to the DOM"
  end

  test "CL-060 should fail when element detaches after animation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/animating-button.html")
    Page.evaluate!(page, "addButton()")
    handle = Page.query_selector!(page, "button")
    promise = Runtime.Promise.async(fn -> ElementHandle.click(handle) end)
    Page.evaluate!(page, "stopButton(true)")
    {:error, error} = Runtime.Promise.await(promise)
    assert Page.evaluate!(page, "window.clicked") == nil
    assert Exception.message(error) =~ "Element is not attached to the DOM"
  end

  test "CL-061 should retry when element detaches after animation", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/animating-button.html")
    Page.evaluate!(page, "addButton()")
    promise = Runtime.Promise.async(fn -> Page.click!(page, "button") end, shared: true)
    refute done?(promise)
    assert Page.evaluate!(page, "window.clicked") == nil
    Page.evaluate!(page, "stopButton(true)")
    Page.evaluate!(page, "addButton()")
    refute done?(promise)
    assert Page.evaluate!(page, "window.clicked") == nil
    Page.evaluate!(page, "stopButton(true)")
    Page.evaluate!(page, "addButton()")
    refute done?(promise)
    assert Page.evaluate!(page, "window.clicked") == nil
    Page.evaluate!(page, "stopButton(false)")
    Runtime.Promise.await(promise)
    assert Page.evaluate!(page, "clicked") == true
  end

  @animating_from_outside """
  <style>
    @keyframes move {
      from { left: -300px; }
      to { left: 0; }
    }
    button {
      position: absolute;
      left: -300px;
      top: 0;
      bottom: 0;
      width: 200px;
    }
    button.animated {
      animation: 1s linear 1s move forwards;
    }
    </style>
    <div style="position: relative; width: 300px; height: 300px;">
      <button onclick="window.clicked=true"></button>
    </div>
  """

  test "CL-062 should retry when element is animating from outside the viewport", %{page: page} do
    Page.set_content!(page, @animating_from_outside)
    handle = Page.query_selector!(page, "button")
    promise = Runtime.Promise.async(fn -> ElementHandle.click!(handle) end)
    JSHandle.evaluate!(handle, "button => button.className = 'animated'")
    Runtime.Promise.await(promise)
    assert Page.evaluate!(page, "clicked") == true
  end

  test "CL-063 should fail when element is animating from outside the viewport with force", %{page: page} do
    Page.set_content!(page, @animating_from_outside)
    handle = Page.query_selector!(page, "button")
    promise = Runtime.Promise.async(fn -> ElementHandle.click(handle, force: true) end)
    JSHandle.evaluate!(handle, "button => button.className = 'animated'")
    {:error, error} = Runtime.Promise.await(promise)
    assert Page.evaluate!(page, "window.clicked") == nil
    assert Exception.message(error) =~ "Element is outside of the viewport"
  end

  test "CL-064 should dispatch microtasks in order", %{page: page} do
    Page.set_content!(page, """
      <button id=button>Click me</button>
      <script>
        let mutationCount = 0;
        const observer = new MutationObserver((mutationsList, observer) => {
          for(let mutation of mutationsList)
            ++mutationCount;
        });
        observer.observe(document.body, { attributes: true, childList: true, subtree: true });
        button.addEventListener('mousedown', () => {
          mutationCount = 0;
          document.body.appendChild(document.createElement('div'));
        });
        button.addEventListener('mouseup', () => {
          window['result'] = mutationCount;
        });
      </script>
    """)

    Page.click!(page, "button")
    assert Page.evaluate!(page, "() => window['result']") == 1
  end

  test "CL-065 should click the button when window.innerWidth is corrupted", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.evaluate!(page, "() => Object.defineProperty(window, 'innerWidth', { value: 0 })")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "result") == "Clicked"
  end

  test "CL-066 should click zero-sized input by label", %{page: page} do
    Page.set_content!(page, """
      <label>
        Click me
        <input onclick="window.__clicked=true" style="width:0;height:0;padding:0;margin:0;border:0;">
      </label>
    """)

    Page.click!(page, "text=Click me")
    assert Page.evaluate!(page, "window.__clicked") == true
  end

  test "CL-067 should not throw protocol error when navigating during the click"

  test "CL-068 should retry when navigating during the click"

  test "CL-069 should not hang when frame is detached"

  test "CL-070 should climb dom for inner label with pointer-events:none", %{page: page} do
    Page.set_content!(
      page,
      ~s(<button onclick="window.__CLICKED=true;"><label style="pointer-events:none">Click target</label></button>)
    )

    Page.click!(page, "text=Click target")
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-071 should climb up to [role=button]", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div role=button onclick="window.__CLICKED=true;"><div style="pointer-events:none"><span><div>Click target</div></span></div>)
    )

    Page.click!(page, "text=Click target")
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-072 should climb up to a anchor", %{page: page} do
    # For Firefox its not allowed to return anything: https://bugzilla.mozilla.org/show_bug.cgi?id=1392046
    # Note the intermediate div - it is necessary, otherwise <a><non-clickable/></a> is not recognized as a clickable link.
    Page.set_content!(
      page,
      ~s(<a href="#" onclick="window.__CLICKED=true" id="outer"><div id="intermediate"><div id="inner" style="pointer-events: none">Inner</div></div></a>)
    )

    Page.click!(page, "#inner")
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  test "CL-073 should climb up to a [role=link]", %{page: page} do
    Page.set_content!(
      page,
      ~s(<div role=link onclick="window.__CLICKED=true" id="outer"><div id="inner" style="pointer-events: none">Inner</div></div>)
    )

    Page.click!(page, "#inner")
    assert Page.evaluate!(page, "__CLICKED") == true
  end

  @iframe_target """
    <style>
      body, html { margin: 0; padding: 0; }
      div { margin-left: 10px; margin-top: 20px; width: 2px; height: 2px; }
    </style>
    <div>Target</div>
    <script>
      document.querySelector('div').addEventListener('click', () => window.top._clicked = true);
    </script>
  """

  test "CL-074 should click in an iframe with border", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; border: none; box-sizing: border-box; }
        iframe { border: 4px solid black; background: gray; margin-left: 33px; margin-top: 24px; width: 400px; height: 400px; }
      </style>
      <iframe srcdoc="#{@iframe_target}"></iframe>
    """)

    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("div")
    Locator.click!(locator)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "CL-075 should click in an iframe with border 2", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; border: none; }
        iframe { border: 4px solid black; background: gray; margin-left: 33px; margin-top: 24px; width: 400px; height: 400px; }
      </style>
      <iframe srcdoc="#{@iframe_target}"></iframe>
    """)

    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("div")
    Locator.click!(locator)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "CL-076 should not retain removed iframe after clicking inside it", %{page: page} do
    # it.skip(isAndroid, 'requesting gc is not enough');
    Page.set_content!(page, ~s|<iframe srcdoc="<button>Click</button>"></iframe>|)
    button = page |> Page.frame_locator("iframe") |> FrameLocator.get_by_role(:button)
    Locator.wait_for!(button)

    Page.evaluate!(page, """
    () => {
      window.iframeRef = new WeakRef(document.querySelector('iframe'));
    }
    """)

    Locator.click!(button)
    Page.evaluate!(page, "() => document.querySelector('iframe').remove()")
    # Move the mouse away to release Chromium's own last-hovered-node retention.
    Mouse.move!(Page.mouse(page), 500, 500)
    Page.request_gc!(page)
    retained = Page.evaluate!(page, "() => Boolean(window.iframeRef.deref())")
    assert retained == false
  end

  test "CL-077 should click in a transformed iframe", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; border: none; }
        iframe {
          border: 4px solid black;
          background: gray;
          margin-left: 33px;
          margin-top: 24px;
          width: 400px;
          height: 400px;
          transform: translate(100px, 100px) scale(1.2) rotate3d(1, 1, 1, 25deg);
        }
      </style>
      <iframe srcdoc="#{@iframe_target}"></iframe>
    """)

    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("div")
    Locator.click!(locator)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "CL-078 should click a button that is overlaid by a permission popup", %{page: page, server: server} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/23280' });
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <style>body, html { padding: 0; margin: 0; }</style>
      <script type='text/javascript'>
        window.addEventListener('DOMContentLoaded', () => {
          // Viewport filled with buttons.
          for (let i = 0; i < 100; ++i) {
            const button = document.createElement('button');
            button.textContent = i;
            button.style.setProperty('width', '50px');
            button.style.setProperty('height', '50px');
            document.body.append(button);
          }
        }, false);
      </script>
    """)

    # Issue a geolocation request. This should show a browser popup.
    # NOTE: this is a bit racy since we can't wait for the geolocation
    # popup to be shown.
    Page.evaluate!(page, "() => { navigator.geolocation.getCurrentPosition(position => { }); }")
    # If popup blocks the click, then some of the `page.click` calls below will hang.
    for i <- 0..29, do: Page.click!(page, "text=#{i}")
  end

  test "CL-079 should click in a transformed iframe with force", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; border: none; }
        iframe { background: gray; margin-left: 33px; margin-top: 24px; width: 400px; height: 400px; transform: translate(-40px, -40px) scale(0.8); }
      </style>
      <iframe srcdoc="#{@iframe_target}"></iframe>
    """)

    locator = page |> Page.frame_locator("iframe") |> FrameLocator.locator("div")
    Locator.click!(locator, force: true)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "CL-080 should click in a nested transformed iframe", %{page: page} do
    Page.set_content!(page, """
      <style>
        body, html, iframe { margin: 0; padding: 0; box-sizing: border-box; }
        iframe { border: 1px solid black; background: gray; margin-left: 33px; margin-top: 24px; width: 400px; height: 400px; transform: scale(0.8); }
      </style>
      <iframe srcdoc="
        <style>
          body, html, iframe { margin: 0; padding: 0; box-sizing: border-box; }
          iframe { border: 3px solid black; background: gray; margin-left: 18px; margin-top: 14px; width: 200px; height: 200px; transform: scale(0.7); }
        </style>
        <iframe srcdoc='
          <style>
            div { margin-left: 10px; margin-top: 20px; width: 2px; height: 2px; }
          </style>
          <div>Target</div>
        '></iframe>
      "></iframe>
    """)

    locator =
      page |> Page.frame_locator("iframe") |> FrameLocator.frame_locator("iframe") |> FrameLocator.locator("div")

    Locator.evaluate!(locator, "div => { div.addEventListener('click', () => window.top['_clicked'] = true); }")
    Locator.click!(locator)
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "CL-081 ensure events are dispatched in the individual tasks", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/19685' });
    Page.set_content!(page, """
      <div id="outer" style="background: #d4d4d4; width: 60px; height: 60px;">
        <div id="inner" style="background: #adadad; width: 46px; height: 46px;"></div>
      </div>
    """)

    Page.evaluate!(page, """
    () => {
      function onClick(name) {
        console.log(`click ${name}`);

        window.builtins.setTimeout(function() {
          console.log(`timeout ${name}`);
        }, 0);

        void Promise.resolve().then(function() {
          console.log(`promise ${name}`);
        });
      }

      document.getElementById('inner').addEventListener('click', () => onClick('inner'));
      document.getElementById('outer').addEventListener('click', () => onClick('outer'));
    }
    """)

    # Capture console messages
    messages = collect_console(page)

    # Click on the inner div element
    Locator.click!(Page.locator(page, "#inner"))

    expected = ["click inner", "promise inner", "click outer", "promise outer", "timeout inner", "timeout outer"]
    assert poll(messages, expected) == expected
  end

  test "CL-082 should click if opened select covers the button", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/23618' });
    Page.set_content!(page, """
      <div>
        <select>
          <option>very long text #1</option>
          <option>very long text #2</option>
          <option>very long text #3</option>
          <option>very long text #4</option>
          <option>very long text #5</option>
          <option>very long text #6</option>
        </select>
      </div>
      <div>
        <button onclick="window.__CLICKED=42">clickme</button>
      </div>
    """)

    Page.click!(page, "select")
    Page.click!(page, "button")
    assert Page.evaluate!(page, "window.__CLICKED") == 42
  end

  test "CL-083 should fire contextmenu event on right click in correct order",
       %{page: page, server: server, browser_name: browser_name} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/26515' });
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
      <button id="target">Click me</button>
    """)

    Page.evaluate!(page, """
    () => {
      const logEvent = e => console.log(e.type);
      document.addEventListener('mousedown', logEvent);
      document.addEventListener('mouseup', logEvent);
      document.addEventListener('contextmenu', logEvent);
    }
    """)

    entries = collect_console(page)
    page |> Page.get_by_role("button", name: "Click me") |> Locator.click!(button: :right)

    expected =
      if browser_name == "chromium" and match?({:win32, _}, :os.type()),
        do: ["mousedown", "mouseup", "contextmenu"],
        else: ["mousedown", "contextmenu", "mouseup"]

    assert poll(entries, expected) == expected
  end

  test "CL-084 should click after a right click", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/39246' }
    Page.set_content!(page, """
      <button>Click me</button>
      <script>
        const button = document.querySelector('button');
        button.addEventListener('click', () => button.textContent = 'Clicked!');
      </script>
    """)

    page |> Page.get_by_role("button") |> Locator.click!(button: :right)
    page |> Page.get_by_role("button") |> Locator.click!()
    Expect.to_have_text!(Page.get_by_role(page, "button"), "Clicked!")
  end

  test "CL-085 should set PointerEvent.pressure on pointerdown", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/35844' });
    Page.set_content!(page, """
      <button id="target">Click me</button>
      <script>
        window['pressures'] = [];
        document.addEventListener('pointerdown', e => window['pressures'].push(['pointerdown', e.pressure]));
        document.addEventListener('pointerup', e => window['pressures'].push(['pointerup', e.pressure]));
      </script>
    """)

    Page.click!(page, "button")
    pressures = Page.evaluate!(page, "() => window['pressures']")
    # expect.arrayContaining
    for entry <- [["pointerdown", 0.5], ["pointerup", 0]], do: assert(entry in pressures)
  end

  test "CL-086 should set PointerEvent.pressure on pointermove", %{page: page} do
    # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/35844' });
    # it.fixme(isAndroid, 'Android coordinates seem to have rounding issues.');
    Page.set_content!(page, """
      <body style="margin: 0; padding: 0;">
        <div id="target" style="width: 500px; height: 500px; background-color: red;"></div>
        <script>
          window['pressures'] = [];
          document.addEventListener('pointermove', e => window['pressures'].push([e.pressure, e.clientX, e.clientY]));
        </script>
      </body>
    """)

    Page.click!(page, "div#target")
    mouse = Page.mouse(page)
    Mouse.move!(mouse, 10, 10)
    Mouse.down!(mouse)
    Mouse.move!(mouse, 250, 250)
    Mouse.up!(mouse)
    Mouse.move!(mouse, 50, 50)
    pressures = Page.evaluate!(page, "() => window['pressures']")
    # expect.arrayContaining
    for entry <- [[0, 250, 250], [0, 10, 10], [0.5, 250, 250], [0, 50, 50]], do: assert(entry in pressures)
  end

  test "CL-087 should click into shadow root with slotted div", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/37768' }
    Page.set_content!(page, """
      <my-button>
        <template shadowrootmode="open">
          <button><slot></slot></button>
        </template>
        <div>Foo</div>
      </my-button>
    """)

    page |> Page.get_by_role("button", name: "Foo") |> Locator.click!()
  end

  test "CL-088 should click shadow root button", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/37768' }
    Page.set_content!(page, """
      <my-button>
        <template shadowrootmode="open">
          <button><slot></slot></button>
        </template>
        <div>Foo</div>
      </my-button>
    """)

    page |> Page.locator("my-button") |> Locator.click!()
  end

  test "CL-089 should click with tweened mouse movement", %{page: page, browser_name: browser_name} do
    # it.skip(isAndroid, 'Bad rounding'); it.skip(!headless, 'System cursor tends to interfere with this test');
    Page.set_content!(page, """
      <body style="margin: 0; padding: 0; height: 500px; width: 500px;">
        <div style="position: relative; top: 280px; left: 150px; width: 100px; height: 40px">Click me</div>
      </body>
    """)

    # The test becomes flaky on WebKit without next line.
    if browser_name == "webkit", do: Page.evaluate!(page, "() => new Promise(requestAnimationFrame)")
    Mouse.move!(Page.mouse(page), 100, 100)

    Page.evaluate!(page, """
    () => {
      window['result'] = [];
      document.addEventListener('mousemove', event => {
        window['result'].push([event.clientX, event.clientY]);
      });
    }
    """)

    # Centerpoint at 150 + 100/2, 280 + 40/2 = 200, 300
    page |> Page.locator("div") |> Locator.click!(steps: 5)
    assert Page.evaluate!(page, "result") == [[120, 140], [140, 180], [160, 220], [180, 260], [200, 300]]
  end

  test "CL-090 should abort via signal", %{page: page} do
    Page.set_content!(page, ~s|<button style="display:none">click me</button>|)
    controller = AbortController.new()

    task =
      Runtime.Promise.async(fn ->
        page |> Page.locator("button") |> Locator.click(signal: AbortController.signal(controller), timeout: 0)
      end)

    # Give the action time to start and emit call log entries before aborting.
    Page.wait_for_timeout!(page, 500)

    reason = %RuntimeError{message: "foo bar"}
    AbortController.abort(controller, reason)
    {:error, error} = Runtime.Promise.await(task)
    assert error.message =~ "locator.click: foo bar"
    assert error.message =~ ~r/Call log:[\s\S]*operation was aborted: foo bar/
    assert error.name == "AbortError"
    assert error.cause == reason
  end

  test "CL-091 should throw an Error when aborted in-flight with a string reason", %{page: page} do
    Page.set_content!(page, ~s|<button style="display:none">click me</button>|)
    controller = AbortController.new()

    promise =
      Runtime.Promise.async(fn ->
        page |> Page.locator("button") |> Locator.click(signal: AbortController.signal(controller), timeout: 0)
      end)

    AbortController.abort(controller, "aborted by user")
    {:error, error} = Runtime.Promise.await(promise)
    assert is_exception(error)
    assert error.message =~ "locator.click: aborted by user"
    assert error.name == "AbortError"
    assert error.cause == "aborted by user"
  end

  test "CL-092 should abort via already-aborted signal", %{page: page} do
    Page.set_content!(page, "<button>click me</button>")
    controller = AbortController.new()
    reason = %RuntimeError{message: "Already aborted"}
    AbortController.abort(controller, reason)

    {:error, error} =
      page |> Page.locator("button") |> Locator.click(signal: AbortController.signal(controller))

    assert error.message =~ "The operation was aborted"
    assert error.name == "AbortError"
    assert error.cause == reason
  end

  test "CL-093 should throw an Error when aborted via an already-aborted signal with a string reason", %{page: page} do
    Page.set_content!(page, "<button>click me</button>")
    controller = AbortController.new()
    AbortController.abort(controller, "already aborted")

    {:error, error} =
      page |> Page.locator("button") |> Locator.click(signal: AbortController.signal(controller))

    assert is_exception(error)
    assert error.name == "AbortError"
    assert error.cause == "already aborted"
  end
end
