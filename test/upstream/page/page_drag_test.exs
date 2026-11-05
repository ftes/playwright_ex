defmodule PlaywrightEx.Page.PageDragTest do
  @upstream "tests/page/page-drag.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.Utils

  @moduletag :page

  # it.skip(browserName === 'chromium' && browserMajorVersion < 91)  -- we run a recent chromium
  # it.skip(isAndroid), it.skip(!headless)  -- we run desktop browsers headless

  @source_in_target "target => target.contains(document.querySelector('#source'))"

  describe "Drag and drop" do
    test "should work @smoke", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")
      Page.hover!(page, "#source")
      Mouse.down!(Page.mouse(page))
      Page.hover!(page, "#target")
      Mouse.up!(Page.mouse(page))
      # could not find source in target
      assert Page.eval_on_selector!(page, "#target", @source_in_target) == true
    end

    test "should send the right events", %{page: page, server: server, browser_name: browser_name} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")
      events = track_events(Page.query_selector!(page, "body"))
      Page.hover!(page, "#source")
      Mouse.down!(Page.mouse(page))
      Page.hover!(page, "#target")
      Mouse.up!(Page.mouse(page))

      assert JSHandle.json_value!(events) == [
               "mousemove at 120;86",
               "mousedown at 120;86",
               if(browser_name == "firefox", do: "dragstart at 120;86", else: "mousemove at 240;350"),
               if(browser_name == "firefox", do: "mousemove at 240;350", else: "dragstart at 120;86"),
               "dragenter at 240;350",
               "dragover at 240;350",
               "drop at 240;350",
               "dragend"
             ]
    end

    @tag skip: if(@browser_name != "chromium", do: "upstream fixme: not chromium")
    test "should not send dragover on the first mousemove", %{page: page, server: server, browser_name: browser_name} do
      # it.fixme(browserName !== 'chromium');
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")
      events = track_events(Page.query_selector!(page, "body"))
      Page.hover!(page, "#source")
      Mouse.down!(Page.mouse(page))
      Page.hover!(page, "#target")

      assert JSHandle.json_value!(events) == [
               "mousemove at 120;86",
               "mousedown at 120;86",
               if(browser_name == "firefox", do: "dragstart at 120;86", else: "mousemove at 240;350"),
               if(browser_name == "firefox", do: "mousemove at 240;350", else: "dragstart at 120;86"),
               "dragenter at 240;350"
             ]
    end

    test "should work inside iframe", %{page: page, server: server, browser_name: browser_name} do
      Page.goto!(page, server.empty_page)
      frame = Utils.attach_frame(page, "myframe", server.prefix <> "/drag-n-drop.html")

      Page.eval_on_selector!(page, "iframe", """
      iframe => {
        iframe.style.width = '500px';
        iframe.style.height = '600px';
        iframe.style.marginLeft = '80px';
        iframe.style.marginTop = '60px';
      }
      """)

      page_events = track_events(Page.query_selector!(page, "body"))
      frame_events = track_events(Frame.query_selector!(frame, "body"))
      Frame.hover!(frame, "#source")
      Mouse.down!(Page.mouse(page))
      Frame.hover!(frame, "#target")
      Mouse.up!(Page.mouse(page))
      # could not find source in target
      assert Frame.eval_on_selector!(frame, "#target", @source_in_target) == true

      assert JSHandle.json_value!(frame_events) == [
               "mousemove at 120;86",
               "mousedown at 120;86",
               if(browser_name == "firefox", do: "dragstart at 120;86", else: "mousemove at 240;350"),
               if(browser_name == "firefox", do: "mousemove at 240;350", else: "dragstart at 120;86"),
               "dragenter at 240;350",
               "dragover at 240;350",
               "drop at 240;350",
               "dragend"
             ]

      assert JSHandle.json_value!(page_events) == []
    end

    test "should cancel on escape", %{page: page, server: server, browser_name: browser_name} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")
      events = track_events(Page.query_selector!(page, "body"))
      Page.hover!(page, "#source")
      Mouse.down!(Page.mouse(page))
      Page.hover!(page, "#target")
      Keyboard.press!(Page.keyboard(page), "Escape")
      Mouse.up!(Page.mouse(page))
      # found source in target
      assert Page.eval_on_selector!(page, "#target", @source_in_target) == false

      assert JSHandle.json_value!(events) ==
               Enum.filter(
                 [
                   "mousemove at 120;86",
                   "mousedown at 120;86",
                   if(browser_name == "firefox", do: "dragstart at 120;86", else: "mousemove at 240;350"),
                   if(browser_name == "firefox", do: "mousemove at 240;350", else: "dragstart at 120;86"),
                   "dragenter at 240;350",
                   if(browser_name == "chromium", do: nil, else: "dragover at 240;350"),
                   "dragend",
                   "mouseup at 240;350"
                 ],
                 & &1
               )
    end

    # describe "iframe" (nested describe: ExUnit has none)
    # it.fixme(true, 'implement dragging with iframes');

    @tag skip: "upstream fixme: implement dragging with iframes"
    test "should drag into an iframe"

    @tag skip: "upstream fixme: implement dragging with iframes"
    test "should drag out of an iframe"

    @tag skip:
           if(@browser_name == "webkit" and not match?({:unix, :linux}, :os.type()),
             do: "upstream fixme: WebKit doesn't handle the drop effect correctly outside of linux."
           )
    test "should respect the drop effect", %{page: page} do
      # it.fixme(browserName === 'webkit' && !isLinux, 'WebKit doesn\'t handle the drop effect correctly outside of linux.');
      # it.fixme(webkit && isLinux && !headless), it.fixme(chromium && !isMac && !headless)  -- we run headless
      assert test_if_dropped(page, "copy", "copy") == true
      assert test_if_dropped(page, "copy", "move") == false
      assert test_if_dropped(page, "all", "link") == true
      assert test_if_dropped(page, "all", "none") == false

      assert test_if_dropped(page, "copyMove", "copy") == true
      assert test_if_dropped(page, "copyLink", "copy") == true
      assert test_if_dropped(page, "linkMove", "copy") == false

      assert test_if_dropped(page, "copyMove", "link") == false
      assert test_if_dropped(page, "copyLink", "link") == true
      assert test_if_dropped(page, "linkMove", "link") == true

      assert test_if_dropped(page, "copyMove", "move") == true
      assert test_if_dropped(page, "copyLink", "move") == false
      assert test_if_dropped(page, "linkMove", "move") == true

      assert test_if_dropped(page, "uninitialized", "copy") == true
    end

    test "should work if the drag is canceled", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")

      Page.evaluate!(page, """
      () => {
        document.body.addEventListener('dragstart', event => {
          event.preventDefault();
        }, false);
      }
      """)

      Page.hover!(page, "#source")
      Mouse.down!(Page.mouse(page))
      Page.hover!(page, "#target")
      Mouse.up!(Page.mouse(page))
      assert Page.eval_on_selector!(page, "#target", @source_in_target) == false
    end

    test "should work if the drag event is captured but not canceled", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")

      Page.evaluate!(page, """
      () => {
        document.body.addEventListener('dragstart', event => {
          event.stopImmediatePropagation();
        }, false);
      }
      """)

      Page.hover!(page, "#source")
      Mouse.down!(Page.mouse(page))
      Page.hover!(page, "#target")
      Mouse.up!(Page.mouse(page))
      assert Page.eval_on_selector!(page, "#target", @source_in_target) == true
    end

    test "should be able to drag the mouse in a frame", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/frames/one-frame.html")
      events_handle = track_events(Frame.query_selector!(Enum.at(Page.frames(page), 1), "html"))
      Mouse.move!(Page.mouse(page), 30, 30)
      Mouse.down!(Page.mouse(page))
      Mouse.move!(Page.mouse(page), 60, 60)
      Mouse.up!(Page.mouse(page))

      assert JSHandle.json_value!(events_handle) == [
               "mousemove at 20;20",
               "mousedown at 20;20",
               "mousemove at 50;50",
               "mouseup at 50;50"
             ]
    end

    test "should work if a frame is stalled", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")
      test = self()
      Page.route!(page, "**/empty.html", fn route, _request -> send(test, {:made_request, route}) end)

      spawn(fn ->
        try do
          Utils.attach_frame(page, "frame", server.empty_page)
        rescue
          _ -> nil
        end
      end)

      assert_receive {:made_request, route}, 5000
      Page.hover!(page, "#source")
      Mouse.down!(Page.mouse(page))
      Page.hover!(page, "#target")
      Mouse.up!(Page.mouse(page))
      Route.abort!(route)
      # could not find source in target
      assert Page.eval_on_selector!(page, "#target", @source_in_target) == true
    end

    test "should work with the helper method", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")
      Page.drag_and_drop!(page, "#source", "#target")
      # could not find source in target
      assert Page.eval_on_selector!(page, "#target", @source_in_target) == true
    end

    for title <- ["dragAndDrop", "dragTo"] do
      test "should #{title} with tweened mouse movement", %{page: page} do
        # it.skip(!headless, 'actual mouse interferes with the exact mousemove events')  -- we run headless
        Page.set_content!(page, """
        <body style="margin: 0; padding: 0;">
          <div style="width:100px;height:100px;background:red;" id="red"></div>
          <div style="width:300px;height:100px;background:blue;" id="blue"></div>
        </body>
        """)

        events_handle =
          Page.evaluate_handle!(page, """
          () => {
            const events = [];
            document.addEventListener('mousedown', event => {
              events.push({
                type: 'mousedown',
                x: event.pageX,
                y: event.pageY,
              });
            });
            document.addEventListener('mouseup', event => {
              events.push({
                type: 'mouseup',
                x: event.pageX,
                y: event.pageY,
              });
            });
            document.addEventListener('mousemove', event => {
              events.push({
                type: 'mousemove',
                x: event.pageX,
                y: event.pageY,
              });
            });
            return events;
          }
          """)

        drag(unquote(title), page, 4)

        assert poll(fn -> JSHandle.json_value!(events_handle) end, [
                 %{"type" => "mousemove", "x" => 50, "y" => 50},
                 %{"type" => "mousedown", "x" => 50, "y" => 50},
                 %{"type" => "mousemove", "x" => 75, "y" => 75},
                 %{"type" => "mousemove", "x" => 100, "y" => 100},
                 %{"type" => "mousemove", "x" => 125, "y" => 125},
                 %{"type" => "mousemove", "x" => 150, "y" => 150},
                 %{"type" => "mouseup", "x" => 150, "y" => 150}
               ])
      end
    end

    test "should allow specifying the position", %{page: page} do
      Page.set_content!(page, """
      <div style="width:100px;height:100px;background:red;" id="red">
      </div>
      <div style="width:100px;height:100px;background:blue;" id="blue">
      </div>
      """)

      events_handle =
        Page.evaluate_handle!(page, """
        () => {
          const events = [];
          document.getElementById('red').addEventListener('mousedown', event => {
            events.push({
              type: 'mousedown',
              x: event.offsetX,
              y: event.offsetY,
            });
          });
          document.getElementById('blue').addEventListener('mouseup', event => {
            events.push({
              type: 'mouseup',
              x: event.offsetX,
              y: event.offsetY,
            });
          });
          return events;
        }
        """)

      Page.drag_and_drop!(page, "#red", "#blue",
        source_position: %{x: 34, y: 7},
        target_position: %{x: 10, y: 20}
      )

      assert JSHandle.json_value!(events_handle) == [
               %{"type" => "mousedown", "x" => 34, "y" => 7},
               %{"type" => "mouseup", "x" => 10, "y" => 20}
             ]
    end

    test "should work with locators", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/drag-n-drop.html")
      Locator.drag_to!(Page.locator(page, "#source"), Page.locator(page, "#target"))
      # could not find source in target
      assert Page.eval_on_selector!(page, "#target", @source_in_target) == true
    end
  end

  test "should work if not doing a drag", %{page: page} do
    events_handle = track_events(Page.query_selector!(page, "html"))
    Mouse.move!(Page.mouse(page), 50, 50)
    Mouse.down!(Page.mouse(page))
    Mouse.move!(Page.mouse(page), 100, 100)
    Mouse.up!(Page.mouse(page))

    assert JSHandle.json_value!(events_handle) == [
             "mousemove at 50;50",
             "mousedown at 50;50",
             "mousemove at 100;100",
             "mouseup at 100;100"
           ]
  end

  test "should report event.buttons", %{page: page} do
    logs_handle =
      Page.evaluate_handle!(page, """
      async () => {
        const div = document.createElement('div');
        document.body.appendChild(div);
        div.style.width = '200px';
        div.style.height = '200px';
        div.style.backgroundColor = 'blue';
        div.addEventListener('mousedown', onEvent);
        div.addEventListener('mousemove', onEvent, { passive: false });
        div.addEventListener('mouseup', onEvent);
        const logs = [];
        function onEvent(event) {
          logs.push({ type: event.type, buttons: event.buttons });
        }
        await new Promise(window.builtins.requestAnimationFrame);
        return logs;
      }
      """)

    Mouse.move!(Page.mouse(page), 20, 20)
    Mouse.down!(Page.mouse(page))
    Mouse.move!(Page.mouse(page), 40, 40)
    Mouse.up!(Page.mouse(page))
    logs = JSHandle.json_value!(logs_handle)

    assert logs == [
             %{"type" => "mousemove", "buttons" => 0},
             %{"type" => "mousedown", "buttons" => 1},
             %{"type" => "mousemove", "buttons" => 1},
             %{"type" => "mouseup", "buttons" => 0}
           ]
  end

  @tag skip: if(@browser_name == "webkit" and match?({:win32, _}, :os.type()), do: "upstream fixme: webkit on Windows")
  test "should handle custom dataTransfer", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/18013' }
    # it.fixme(browserName === 'webkit' && isWindows);
    Page.set_content!(page, ~s(<button draggable="true">Draggable</button>))

    result_promise =
      Task.async(fn ->
        Page.evaluate!(page, """
        () =>
          new Promise(resolve => {
            document.addEventListener('dragstart', event => {
              event.dataTransfer.setData('custom-type', 'Hello World');
            }, false);

            document.addEventListener('dragenter', event => {
              event.preventDefault();
            }, false);
            document.addEventListener('dragover', event => {
              event.preventDefault();
            }, false);

            document.addEventListener('drop', event => {
              event.preventDefault();
              resolve({
                types: event.dataTransfer.types,
                data: event.dataTransfer.getData('custom-type'),
              });
            }, false);
          })
        """)
      end)

    Page.hover!(page, ~s([draggable="true"]))
    Mouse.down!(Page.mouse(page))
    Mouse.move!(Page.mouse(page), 100, 100)
    Mouse.up!(Page.mouse(page))

    assert Task.await(result_promise, :infinity) == %{"types" => ["custom-type"], "data" => "Hello World"}
  end

  test "what happens when dragging element is destroyed", %{page: page} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/21621' }
    Page.set_content!(page, """
    <button draggable="true">Draggable</button>
    <div id=target>drop here</div>
    """)

    Page.evaluate!(page, """
    () => {
      document.querySelector('#target').addEventListener('dragover', event => {
        document.querySelector('button')?.remove();
      }, false);

      document.querySelector('#target').addEventListener('drop', event => {
        document.querySelector('#target').textContent = 'dropped';
      }, false);
    }
    """)

    Locator.drag_to!(Page.locator(page, "button"), Page.locator(page, "div"))
    Expect.to_have_text!(Page.locator(page, "div"), "drop here")
  end

  # `drag` of the forEach above.
  defp drag("dragAndDrop", page, steps), do: Page.drag_and_drop!(page, "#red", "#blue", steps: steps)

  defp drag("dragTo", page, steps),
    do: Locator.drag_to!(Page.locator(page, "#red"), Page.locator(page, "#blue"), steps: steps)

  defp test_if_dropped(page, effect_allowed, drop_effect) do
    Page.set_content!(page, """
    <div draggable="true">drag target</div>
    <drop-target>this is the drop target</drop-target>
    """)

    Page.evaluate!(
      page,
      """
      ({ effectAllowed, dropEffect }) => {
        window['dropped'] = false;

        document.querySelector('div').addEventListener('dragstart', event => {
          event.dataTransfer.effectAllowed = effectAllowed;
          event.dataTransfer.setData('text/plain', 'drag data');
        });

        const dropTarget = document.querySelector('drop-target');
        dropTarget.addEventListener('dragover', event => {
          event.dataTransfer.dropEffect = dropEffect;
          event.preventDefault();
        });
        dropTarget.addEventListener('drop', event => {
          window['dropped'] = true;
        });
      }
      """,
      %{effectAllowed: effect_allowed, dropEffect: drop_effect}
    )

    Page.hover!(page, "div")
    Mouse.down!(Page.mouse(page))
    Page.hover!(page, "drop-target")
    Mouse.up!(Page.mouse(page))
    Page.evaluate!(page, "dropped")
  end

  defp track_events(target) do
    JSHandle.evaluate_handle!(target, """
    target => {
      const events = [];
      for (const event of [
        'mousedown', 'mousemove', 'mouseup',
        'dragstart', 'dragend', 'dragover', 'dragenter', 'dragleave', 'dragexit',
        'drop'
      ]) {
        target.addEventListener(event, e => {
          const pe = e;
          // Browsers are all over the place with dragend position.
          if (event === 'dragend')
            events.push('dragend');
          else
            events.push(`${event} at ${pe.clientX};${pe.clientY}`);
        }, false);
      }
      return events;
    }
    """)
  end

  # `expect.poll(fun).toEqual(expected)`: polls until equal (the 10 s expect timeout).
  defp poll(fun, expected, tries \\ 100) do
    cond do
      fun.() == expected -> true
      tries == 0 -> false
      true -> Process.sleep(100) && poll(fun, expected, tries - 1)
    end
  end
end
