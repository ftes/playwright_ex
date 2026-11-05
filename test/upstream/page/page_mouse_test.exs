defmodule PlaywrightEx.Page.PageMouseTest do
  @upstream "tests/page/page-mouse.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  @is_mac match?({:unix, :darwin}, :os.type())

  @dimensions """
  function dimensions() {
    const rect = document.querySelector('textarea').getBoundingClientRect();
    return {
      x: rect.left,
      y: rect.top,
      width: rect.width,
      height: rect.height
    };
  }
  """

  # config/utils.ts rafraf
  defp rafraf(page, count \\ 1) do
    for _ <- 1..count do
      Page.evaluate!(
        page,
        "() => new Promise(f => window.builtins.requestAnimationFrame(() => window.builtins.requestAnimationFrame(f)))"
      )
    end
  end

  test "should click the document @smoke", %{page: page} do
    Page.evaluate!(page, """
    () => {
      window['clickPromise'] = new Promise(resolve => {
        document.addEventListener('click', event => {
          resolve({
            type: event.type,
            detail: event.detail,
            clientX: event.clientX,
            clientY: event.clientY,
            isTrusted: event.isTrusted,
            button: event.button
          });
        });
      });
    }
    """)

    Mouse.click!(Page.mouse(page), 50, 60)
    event = Page.evaluate!(page, "() => window['clickPromise']")
    assert event["type"] == "click"
    assert event["detail"] == 1
    assert event["clientX"] == 50
    assert event["clientY"] == 60
    assert event["isTrusted"] == true
    assert event["button"] == 0
  end

  test "should dblclick the div", %{page: page} do
    Page.set_content!(page, "<div style='width: 100px; height: 100px;'>Click me</div>")

    Page.evaluate!(page, """
    () => {
      window['dblclickPromise'] = new Promise(resolve => {
        document.querySelector('div').addEventListener('dblclick', event => {
          resolve({
            type: event.type,
            detail: event.detail,
            clientX: event.clientX,
            clientY: event.clientY,
            isTrusted: event.isTrusted,
            button: event.button,
          });
        });
      });
    }
    """)

    Mouse.dblclick!(Page.mouse(page), 50, 60)
    event = Page.evaluate!(page, "() => window['dblclickPromise']")
    assert event["type"] == "dblclick"
    assert event["detail"] == 2
    assert event["clientX"] == 50
    assert event["clientY"] == 60
    assert event["isTrusted"] == true
    assert event["button"] == 0
  end

  test "down and up should generate click", %{page: page} do
    Page.evaluate!(page, """
    () => {
      window['clickPromise'] = new Promise(resolve => {
        document.addEventListener('click', event => {
          resolve({
            type: event.type,
            detail: event.detail,
            clientX: event.clientX,
            clientY: event.clientY,
            isTrusted: event.isTrusted,
            button: event.button
          });
        });
      });
    }
    """)

    Mouse.move!(Page.mouse(page), 50, 60)
    Mouse.down!(Page.mouse(page))
    Mouse.up!(Page.mouse(page))
    event = Page.evaluate!(page, "() => window['clickPromise']")
    assert event["type"] == "click"
    assert event["detail"] == 1
    assert event["clientX"] == 50
    assert event["clientY"] == 60
    assert event["isTrusted"] == true
    assert event["button"] == 0
  end

  test "should pointerdown the div with a custom button", %{page: page, browser_name: browser_name} do
    Page.set_content!(page, "<div style='width: 100px; height: 100px;'>Click me</div>")

    Page.evaluate!(page, """
    () => {
      window['pointerdownPromise'] = new Promise(resolve => {
        document.querySelector('div').addEventListener('pointerdown', event => {
          resolve({
            type: event.type,
            detail: event.detail,
            clientX: event.clientX,
            clientY: event.clientY,
            isTrusted: event.isTrusted,
            button: event.button,
            buttons: event.buttons,
            pointerId: event.pointerId,
          });
        });
      });
    }
    """)

    Mouse.click!(Page.mouse(page), 50, 60, button: :middle)
    event = Page.evaluate!(page, "() => window['pointerdownPromise']")
    assert event["type"] == "pointerdown"
    assert event["detail"] == if(browser_name == "webkit", do: 1, else: 0)
    assert event["clientX"] == 50
    assert event["clientY"] == 60
    assert event["isTrusted"] == true
    assert event["button"] == 1
    assert event["buttons"] == 4
    assert event["pointerId"] == if(browser_name == "firefox", do: 0, else: 1)
  end

  test "should report correct buttons property", %{page: page} do
    Page.evaluate!(page, """
    () => {
      window.__EVENTS = [];
      const handler = event => {
        window.__EVENTS.push({
          type: event.type,
          button: event.button,
          buttons: event.buttons,
        });
      };
      window.addEventListener('mousedown', handler, false);
      window.addEventListener('mouseup', handler, false);
    }
    """)

    Mouse.move!(Page.mouse(page), 50, 60)
    Mouse.down!(Page.mouse(page), button: :middle)
    Mouse.down!(Page.mouse(page), button: :left)
    Mouse.up!(Page.mouse(page), button: :middle)
    Mouse.up!(Page.mouse(page), button: :left)

    assert Page.evaluate!(page, "() => window.__EVENTS") == [
             %{"type" => "mousedown", "button" => 1, "buttons" => 4},
             %{"type" => "mousedown", "button" => 0, "buttons" => 5},
             %{"type" => "mouseup", "button" => 1, "buttons" => 1},
             %{"type" => "mouseup", "button" => 0, "buttons" => 0}
           ]
  end

  test "should report correct pointerType property", %{page: page} do
    Mouse.move!(Page.mouse(page), 50, 60)

    Page.evaluate!(page, """
    () => {
      window.__EVENTS = [];
      const handler = event => {
        window.__EVENTS.push({
          type: event.type,
          pointerType: event.pointerType,
        });
      };
      window.addEventListener('pointerdown', handler, false);
      window.addEventListener('pointermove', handler, false);
      window.addEventListener('pointerup', handler, false);
    }
    """)

    Mouse.move!(Page.mouse(page), 60, 50)
    Mouse.down!(Page.mouse(page))
    Mouse.up!(Page.mouse(page))

    assert Page.evaluate!(page, "() => window.__EVENTS") == [
             %{"type" => "pointermove", "pointerType" => "mouse"},
             %{"type" => "pointerdown", "pointerType" => "mouse"},
             %{"type" => "pointerup", "pointerType" => "mouse"}
           ]
  end

  test "should select the text with mouse", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/textarea.html")
    Page.focus!(page, "textarea")
    text = "This is the text that we are going to try to select. Let's see how it goes."
    Keyboard.type!(Page.keyboard(page), text)
    # Firefox needs an extra frame here after typing or it will fail to set the scrollTop
    rafraf(page)
    Page.evaluate!(page, "() => document.querySelector('textarea').scrollTop = 0")
    %{"x" => x, "y" => y} = Page.evaluate!(page, @dimensions)
    Mouse.move!(Page.mouse(page), x + 2, y + 2)
    Mouse.down!(Page.mouse(page))
    Mouse.move!(Page.mouse(page), 200, 200)
    Mouse.up!(Page.mouse(page))

    assert Page.evaluate!(page, """
           () => {
             const textarea = document.querySelector('textarea');
             return textarea.value.substring(textarea.selectionStart, textarea.selectionEnd);
           }
           """) == text
  end

  test "should trigger hover state", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.hover!(page, "#button-6")
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-6"
    Page.hover!(page, "#button-2")
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-2"
    Page.hover!(page, "#button-91")
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-91"
  end

  test "should trigger hover state on disabled button", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.eval_on_selector!(page, "#button-6", "button => button.disabled = true")
    Page.hover!(page, "#button-6", timeout: 5000)
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-6"
  end

  test "should trigger hover state with removed window.Node", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Page.evaluate!(page, "() => delete window.Node")
    Page.hover!(page, "#button-6")
    assert Page.evaluate!(page, "() => document.querySelector('button:hover').id") == "button-6"
  end

  test "should set modifier keys on click", %{page: page, server: server, browser_name: browser_name} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")

    Page.evaluate!(
      page,
      "() => document.querySelector('#button-3').addEventListener('mousedown', e => window['lastEvent'] = e, true)"
    )

    modifiers = [{"Shift", "shiftKey"}, {"Control", "ctrlKey"}, {"Alt", "altKey"}, {"Meta", "metaKey"}]
    # In Firefox, the Meta modifier only exists on Mac
    modifiers = if browser_name == "firefox" and !@is_mac, do: List.keydelete(modifiers, "Meta", 0), else: modifiers

    for {modifier, mod} <- modifiers do
      Keyboard.down!(Page.keyboard(page), modifier)
      Page.click!(page, "#button-3")
      if !Page.evaluate!(page, "mod => window['lastEvent'][mod]", mod), do: raise(mod <> " should be true")
      Keyboard.up!(Page.keyboard(page), modifier)
    end

    Page.click!(page, "#button-3")

    for {_modifier, mod} <- modifiers do
      if Page.evaluate!(page, "mod => window['lastEvent'][mod]", mod), do: raise(mod <> " should be false")
    end
  end

  test "should tween mouse movement", %{page: page, browser_name: browser_name} do
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

    Mouse.move!(Page.mouse(page), 200, 300, steps: 5)

    assert Page.evaluate!(page, "result") == [
             [120, 140],
             [140, 180],
             [160, 220],
             [180, 260],
             [200, 300]
           ]
  end

  test "should always round down", %{page: page} do
    Page.evaluate!(page, """
    () => {
      document.addEventListener('mousedown', event => {
        window['result'] = [event.clientX, event.clientY];
      });
    }
    """)

    Mouse.click!(Page.mouse(page), 50.1, 50.9)
    assert Page.evaluate!(page, "result") == [50, 50]
  end

  test "should not crash on mouse drag with any button", %{page: page} do
    Page.evaluate!(page, """
    () => {
      // Do not show contextmenu on right click since it is poorly supported.
      window.addEventListener('contextmenu', e => e.preventDefault(), false);
    }
    """)

    for button <- [:left, :middle, :right] do
      Mouse.move!(Page.mouse(page), 50, 50)
      Mouse.down!(Page.mouse(page), button: button)
      Mouse.move!(Page.mouse(page), 100, 100)
    end
  end

  @tag skip:
         if(@browser_name == "chromium" and match?({:win32, _}, :os.type()),
           do: "upstream fixme: context menu support is best-effort for Linux and MacOS"
         )
  test "should dispatch mouse move after context menu was opened", %{page: page} do
    Page.evaluate!(page, """
    () => {
      window['contextMenuPromise'] = new Promise(x => {
        window.addEventListener('contextmenu', x, false);
      });
    }
    """)

    cx = 100
    cy = 100
    Mouse.move!(Page.mouse(page), cx, cy)
    Mouse.down!(Page.mouse(page), button: :right)
    Page.evaluate!(page, "() => window['contextMenuPromise']")
    n = 20

    for radius <- [10, 30, 60, 90], i <- 0..(n - 1) do
      angle = 2 * :math.pi() * i / n
      x = cx + round(radius * :math.cos(angle))
      y = cy + round(radius * :math.sin(angle))
      Mouse.move!(Page.mouse(page), x, y)
    end
  end

  test "should track hover across iframe boundaries", %{page: page} do
    # it.skip(!headless, 'headed messes up with hover');
    Page.set_content!(page, """
      <style>
        body, html { margin: 0; padding: 0; }
        #parentBox { position: absolute; left: 10px; top: 10px; width: 100px; height: 100px; }
        iframe { position: absolute; left: 200px; top: 10px; width: 200px; height: 200px; border: none; }
      </style>
      <div id="parentBox"></div>
      <iframe srcdoc="
        <style>body, html { margin: 0; padding: 0; } #childBox { width: 180px; height: 180px; }</style>
        <div id='childBox'></div>
        <script>
          const box = document.querySelector('#childBox');
          box.addEventListener('mouseenter', () => window.top.__log.push('child:enter'));
          box.addEventListener('mouseleave', () => window.top.__log.push('child:leave'));
        </script>
      "></iframe>
      <script>
        window.__log = [];
        const box = document.querySelector('#parentBox');
        box.addEventListener('mouseenter', () => window.__log.push('parent:enter'));
        box.addEventListener('mouseleave', () => window.__log.push('parent:leave'));
      </script>
    """)

    Page.wait_for_selector!(page, "iframe")
    Frame.wait_for_selector!(Enum.at(Page.frames(page), 1), "#childBox")
    log = fn -> Page.evaluate!(page, "() => window['__log']") end
    parent_box = Locator.bounding_box!(Page.locator(page, "#parentBox"))
    iframe_box = Locator.bounding_box!(Page.locator(page, "iframe"))
    parent_center = %{x: parent_box.x + parent_box.width / 2, y: parent_box.y + parent_box.height / 2}
    child_center = %{x: iframe_box.x + 90, y: iframe_box.y + 90}

    Mouse.move!(Page.mouse(page), parent_center.x, parent_center.y)
    Utils.poll(log, &assert(&1 == ["parent:enter"]))

    # Crossing into the iframe leaves the parent element and enters the child.
    Mouse.move!(Page.mouse(page), child_center.x, child_center.y)
    Utils.poll(log, &assert(&1 == ["parent:enter", "parent:leave", "child:enter"]))

    # Crossing back out leaves the child element and re-enters the parent.
    Mouse.move!(Page.mouse(page), parent_center.x, parent_center.y)
    Utils.poll(log, &assert(&1 == ["parent:enter", "parent:leave", "child:enter", "child:leave", "parent:enter"]))
  end
end
