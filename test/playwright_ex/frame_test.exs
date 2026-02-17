defmodule PlaywrightEx.FrameTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Selector

  doctest PlaywrightEx

  describe "mouse move" do
    test "move, down, up", %{page: page, frame: frame} do
      # Navigate to a page with a clickable link
      {:ok, _} = Frame.goto(frame.guid, url: "https://elixir-lang.org/", timeout: @timeout)

      # Get the bounding box of the link and calculate its center's coordinates
      {:ok, result} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            const el = document.querySelector('a[href="/install.html"]');
            const box = el.getBoundingClientRect();
            return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      x = result["x"]
      y = result["y"]

      # Test mouse API: move to the link, then click it using mouse down/up
      {:ok, _} = Page.mouse_move(page.guid, x: x, y: y, timeout: @timeout)
      {:ok, _} = Page.mouse_down(page.guid, timeout: @timeout)
      {:ok, _} = Page.mouse_up(page.guid, timeout: @timeout)

      # Verify navigation to install page
      assert_has(frame.guid, Selector.link("By Operating System"))
    end

    test "hover and manual drag with range slider", %{page: page, frame: frame} do
      # Navigate to a blank page and create a range slider
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            const slider = document.createElement('input');
            slider.type = 'range';
            slider.id = 'slider';
            slider.min = '0';
            slider.max = '100';
            slider.value = '0';
            slider.style.width = '300px';
            slider.style.margin = '100px';
            document.body.appendChild(slider);
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      # Hover over the slider handle
      {:ok, _} = Frame.hover(frame.guid, selector: "#slider", timeout: @timeout)

      # Get the slider handle's position
      {:ok, handle_pos} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            const slider = document.getElementById('slider');
            const box = slider.getBoundingClientRect();
            // For a slider at value 0, the handle is at the left edge
            return { x: box.x, y: box.y + box.height / 2 };
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      # Manual drag: mouse down on handle, drag right, mouse up
      {:ok, _} = Page.mouse_down(page.guid, timeout: @timeout)
      {:ok, _} = Page.mouse_move(page.guid, x: handle_pos["x"] + 150, y: handle_pos["y"], timeout: @timeout)
      {:ok, _} = Page.mouse_up(page.guid, timeout: @timeout)

      # Verify the slider value changed from dragging
      {:ok, final_value} =
        Frame.evaluate(frame.guid,
          expression: "() => document.getElementById('slider').value",
          is_function: true,
          timeout: @timeout
        )

      # The value should have increased from 0 (exact value depends on drag distance)
      assert String.to_integer(final_value) > 0
    end
  end

  describe "is_visible/2" do
    test "returns true/false based on visibility", %{frame: frame} do
      set_html(frame.guid, """
      <div id="visible">Visible</div>
      <div id="hidden" style="display:none">Hidden</div>
      """)

      assert {:ok, true} = Frame.is_visible(frame.guid, selector: "#visible", timeout: @timeout)
      assert {:ok, false} = Frame.is_visible(frame.guid, selector: "#hidden", timeout: @timeout)
    end
  end

  describe "is_checked/2" do
    test "returns true/false based on checked state", %{frame: frame} do
      set_html(frame.guid, """
      <input id="checked" type="checkbox" checked />
      <input id="unchecked" type="checkbox" />
      """)

      assert {:ok, true} = Frame.is_checked(frame.guid, selector: "#checked", timeout: @timeout)
      assert {:ok, false} = Frame.is_checked(frame.guid, selector: "#unchecked", timeout: @timeout)
    end
  end

  describe "is_disabled/2" do
    test "returns true/false based on disabled state", %{frame: frame} do
      set_html(frame.guid, """
      <button id="disabled" disabled>Disabled</button>
      <button id="enabled">Enabled</button>
      """)

      assert {:ok, true} = Frame.is_disabled(frame.guid, selector: "#disabled", timeout: @timeout)
      assert {:ok, false} = Frame.is_disabled(frame.guid, selector: "#enabled", timeout: @timeout)
    end
  end

  describe "is_enabled/2" do
    test "returns true/false based on enabled state", %{frame: frame} do
      set_html(frame.guid, """
      <button id="enabled">Enabled</button>
      <button id="disabled" disabled>Disabled</button>
      """)

      assert {:ok, true} = Frame.is_enabled(frame.guid, selector: "#enabled", timeout: @timeout)
      assert {:ok, false} = Frame.is_enabled(frame.guid, selector: "#disabled", timeout: @timeout)
    end
  end

  describe "is_editable/2" do
    test "returns true/false based on editable state", %{frame: frame} do
      set_html(frame.guid, """
      <input id="editable" type="text" />
      <input id="readonly" type="text" readonly />
      """)

      assert {:ok, true} = Frame.is_editable(frame.guid, selector: "#editable", timeout: @timeout)
      assert {:ok, false} = Frame.is_editable(frame.guid, selector: "#readonly", timeout: @timeout)
    end
  end

  describe "get_attribute/2" do
    setup %{frame: frame} do
      set_html(frame.guid, ~s(<input id="el" type="text" data-testid="input-1" />))
    end

    test "returns attribute value", %{frame: frame} do
      assert {:ok, "text"} = Frame.get_attribute(frame.guid, selector: "#el", name: "type", timeout: @timeout)
      assert {:ok, "input-1"} = Frame.get_attribute(frame.guid, selector: "#el", name: "data-testid", timeout: @timeout)
    end

    test "returns nil for missing attribute", %{frame: frame} do
      assert {:ok, nil} = Frame.get_attribute(frame.guid, selector: "#el", name: "data-nonexistent", timeout: @timeout)
    end
  end

  describe "input_value/2" do
    test "returns value for input and select", %{frame: frame} do
      set_html(frame.guid, """
      <input id="input" type="text" value="hello" />
      <select id="select"><option value="a" selected>A</option></select>
      """)

      assert {:ok, "hello"} = Frame.input_value(frame.guid, selector: "#input", timeout: @timeout)
      assert {:ok, "a"} = Frame.input_value(frame.guid, selector: "#select", timeout: @timeout)
    end
  end

  describe "text_content/2" do
    test "returns text content", %{frame: frame} do
      set_html(frame.guid, ~s(<div id="el">Some text content</div>))
      assert {:ok, "Some text content"} = Frame.text_content(frame.guid, selector: "#el", timeout: @timeout)
    end
  end

  describe "inner_text/2" do
    test "returns inner text", %{frame: frame} do
      set_html(frame.guid, ~s(<div id="el"><span>Inner</span> text</div>))
      assert {:ok, text} = Frame.inner_text(frame.guid, selector: "#el", timeout: @timeout)
      assert text =~ "Inner"
    end
  end

  describe "focus/2" do
    test "focuses an element", %{frame: frame} do
      set_html(frame.guid, ~s(<input id="my-input" type="text" />))
      assert {:ok, _} = Frame.focus(frame.guid, selector: "#my-input", timeout: @timeout)
      assert {:ok, "my-input"} = eval(frame.guid, "() => document.activeElement.id")
    end
  end

  describe "dispatch_event/2" do
    setup %{frame: frame} do
      set_html(frame.guid, ~s(<div id="target">Click me</div>))

      eval(frame.guid, """
      () => {
        window.__clicked = false;
        window.__detail = null;
        document.getElementById('target').addEventListener('click', (e) => {
          window.__clicked = true;
          window.__detail = e.detail;
        });
      }
      """)

      :ok
    end

    test "dispatches a click event", %{frame: frame} do
      assert {:ok, _} = Frame.dispatch_event(frame.guid, selector: "#target", type: "click", timeout: @timeout)
      assert {:ok, true} = eval(frame.guid, "() => window.__clicked")
    end

    test "passes event_init properties", %{frame: frame} do
      assert {:ok, _} =
               Frame.dispatch_event(frame.guid,
                 selector: "#target",
                 type: "click",
                 event_init: %{"detail" => 42},
                 timeout: @timeout
               )

      assert {:ok, 42} = eval(frame.guid, "() => window.__detail")
    end
  end

  describe "wait_for_selector/2" do
    test "waits for hidden state, returns nil", %{frame: frame} do
      set_html(frame.guid, ~s(<div id="el" style="display:none">Hidden</div>))

      assert {:ok, nil} =
               Frame.wait_for_selector(frame.guid, selector: "#el", state: "hidden", timeout: @timeout)
    end

    test "waits for attached state", %{frame: frame} do
      set_html(frame.guid, ~s(<div id="el">Attached</div>))

      assert {:ok, _} =
               Frame.wait_for_selector(frame.guid, selector: "#el", state: "attached", timeout: @timeout)
    end
  end

  describe "wait_for_function/2" do
    test "resolves when expression becomes truthy", %{frame: frame} do
      set_html(frame.guid, "")

      eval(frame.guid, """
      () => {
        window.__ready = false;
        setTimeout(() => { window.__ready = true; }, 100);
      }
      """)

      assert {:ok, %{handle: %{guid: _}}} =
               Frame.wait_for_function(frame.guid,
                 expression: "() => window.__ready",
                 is_function: true,
                 timeout: @timeout
               )
    end

    test "returns a handle for the expression value", %{frame: frame} do
      set_html(frame.guid, "")
      eval(frame.guid, "() => { window.__counter = 42; }")

      assert {:ok, %{handle: %{guid: _}}} =
               Frame.wait_for_function(frame.guid,
                 expression: "() => window.__counter",
                 is_function: true,
                 timeout: @timeout
               )
    end
  end

  describe "wait_for_url/2" do
    test "waits for exact URL match after navigation", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      # Set up a delayed navigation via JS
      eval(frame.guid, """
      () => {
        setTimeout(() => { window.location.href = 'about:blank#target'; }, 100);
      }
      """)

      assert {:ok, _} = Frame.wait_for_url(frame.guid, url: "about:blank#target", timeout: @timeout)
      {:ok, url} = eval(frame.guid, "() => window.location.href")
      assert url == "about:blank#target"
    end

    test "resolves immediately if URL already matches", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = Frame.wait_for_url(frame.guid, url: "about:blank", timeout: @timeout)
    end

    test "supports glob pattern with **", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      eval(frame.guid, """
      () => {
        setTimeout(() => { window.location.hash = '#/dashboard/settings'; }, 100);
      }
      """)

      assert {:ok, _} = Frame.wait_for_url(frame.guid, url: "**settings", timeout: @timeout)
    end

    test "supports single * glob that does not cross path separators", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      eval(frame.guid, """
      () => {
        setTimeout(() => { window.location.hash = '#/users/42/profile'; }, 100);
      }
      """)

      # * should match "42" (single segment) but not cross /
      assert {:ok, _} =
               Frame.wait_for_url(frame.guid, url: "about:blank#/users/*/profile", timeout: @timeout)
    end

    test "handles URLs with regex special characters", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      eval(frame.guid, """
      () => {
        setTimeout(() => { window.location.hash = '#/search?q=foo+bar&page=1'; }, 100);
      }
      """)

      # Characters like ?, +, & should be treated as literals, not regex operators
      assert {:ok, _} =
               Frame.wait_for_url(frame.guid,
                 url: "about:blank#/search?q=foo+bar&page=1",
                 timeout: @timeout
               )
    end

    test "returns error on timeout when URL never matches", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      # Short timeout to quickly verify error handling without slowing the suite
      assert {:error, _} =
               Frame.wait_for_url(frame.guid, url: "https://will-never-match.example", timeout: 500)
    end
  end

  describe "wait_for_load_state/2" do
    test "resolves when page is fully loaded", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = Frame.wait_for_load_state(frame.guid, state: "load", timeout: @timeout)

      {:ok, ready} = eval(frame.guid, "() => document.readyState")
      assert ready == "complete"
    end

    test "resolves for domcontentloaded state", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = Frame.wait_for_load_state(frame.guid, state: "domcontentloaded", timeout: @timeout)

      {:ok, ready} = eval(frame.guid, "() => document.readyState")
      assert ready in ["interactive", "complete"]
    end

    test "networkidle falls back to complete state", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = Frame.wait_for_load_state(frame.guid, state: "networkidle", timeout: @timeout)

      {:ok, ready} = eval(frame.guid, "() => document.readyState")
      assert ready == "complete"
    end

    test "defaults to load state", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = Frame.wait_for_load_state(frame.guid, timeout: @timeout)
    end

    test "actually waits for readyState transition", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      # Override document.readyState to simulate a loading page, then
      # transition to "complete" after a delay to prove waiting works.
      eval(frame.guid, """
      () => {
        let fake = 'loading';
        Object.defineProperty(document, 'readyState', {
          get() { return fake; },
          configurable: true
        });
        setTimeout(() => { fake = 'complete'; }, 200);
      }
      """)

      assert {:ok, _} = Frame.wait_for_load_state(frame.guid, state: "load", timeout: @timeout)

      # Restore real readyState by removing the override
      eval(frame.guid, """
      () => { delete document.readyState; }
      """)
    end
  end

  describe "set_input_files" do
    test "can upload files", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            const input = document.createElement('input');
            input.type = 'file';
            input.id = 'file-input';
            document.body.appendChild(input);
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      tmp_path = Path.join(System.tmp_dir!(), "playwright-test-upload-#{System.unique_integer([:positive])}.txt")
      File.write!(tmp_path, "hello from elixir")

      try do
        {:ok, _} =
          Frame.set_input_files(frame.guid,
            selector: "#file-input",
            local_paths: [tmp_path],
            timeout: @timeout
          )

        {:ok, file_name} =
          Frame.evaluate(frame.guid,
            expression: "() => document.getElementById('file-input').files[0].name",
            is_function: true,
            timeout: @timeout
          )

        {:ok, file_content} =
          Frame.evaluate(frame.guid,
            expression: "() => document.getElementById('file-input').files[0].text()",
            is_function: true,
            timeout: @timeout
          )

        assert file_name == Path.basename(tmp_path)
        assert file_content == "hello from elixir"
      after
        File.rm(tmp_path)
      end
    end
  end
end
