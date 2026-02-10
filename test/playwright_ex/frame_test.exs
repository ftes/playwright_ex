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

  describe "state queries" do
    setup %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            document.body.innerHTML = `
              <div id="visible">Visible</div>
              <div id="hidden" style="display:none">Hidden</div>
              <input id="checkbox" type="checkbox" checked />
              <input id="unchecked" type="checkbox" />
              <button id="disabled-btn" disabled>Disabled</button>
              <button id="enabled-btn">Enabled</button>
              <input id="editable" type="text" value="editable" />
              <input id="readonly" type="text" readonly value="readonly" />
            `;
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      :ok
    end

    test "is_visible/2 returns true for visible element", %{frame: frame} do
      assert {:ok, true} = Frame.is_visible(frame.guid, selector: "#visible", timeout: @timeout)
    end

    test "is_visible/2 returns false for hidden element", %{frame: frame} do
      assert {:ok, false} = Frame.is_visible(frame.guid, selector: "#hidden", timeout: @timeout)
    end

    test "is_checked/2 returns true for checked checkbox", %{frame: frame} do
      assert {:ok, true} = Frame.is_checked(frame.guid, selector: "#checkbox", timeout: @timeout)
    end

    test "is_checked/2 returns false for unchecked checkbox", %{frame: frame} do
      assert {:ok, false} = Frame.is_checked(frame.guid, selector: "#unchecked", timeout: @timeout)
    end

    test "is_disabled/2 returns true for disabled element", %{frame: frame} do
      assert {:ok, true} = Frame.is_disabled(frame.guid, selector: "#disabled-btn", timeout: @timeout)
    end

    test "is_disabled/2 returns false for enabled element", %{frame: frame} do
      assert {:ok, false} = Frame.is_disabled(frame.guid, selector: "#enabled-btn", timeout: @timeout)
    end

    test "is_enabled/2 returns true for enabled element", %{frame: frame} do
      assert {:ok, true} = Frame.is_enabled(frame.guid, selector: "#enabled-btn", timeout: @timeout)
    end

    test "is_enabled/2 returns false for disabled element", %{frame: frame} do
      assert {:ok, false} = Frame.is_enabled(frame.guid, selector: "#disabled-btn", timeout: @timeout)
    end

    test "is_editable/2 returns true for editable input", %{frame: frame} do
      assert {:ok, true} = Frame.is_editable(frame.guid, selector: "#editable", timeout: @timeout)
    end

    test "is_editable/2 returns false for readonly input", %{frame: frame} do
      assert {:ok, false} = Frame.is_editable(frame.guid, selector: "#readonly", timeout: @timeout)
    end
  end

  describe "value and attribute queries" do
    setup %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            document.body.innerHTML = `
              <input id="text-input" type="text" value="hello" data-testid="input-1" />
              <select id="my-select"><option value="a" selected>Option A</option></select>
              <div id="text-div">Some text content</div>
              <div id="inner-div"><span>Inner</span> text</div>
            `;
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      :ok
    end

    test "get_attribute/2 returns attribute value", %{frame: frame} do
      assert {:ok, "text"} = Frame.get_attribute(frame.guid, selector: "#text-input", name: "type", timeout: @timeout)
    end

    test "get_attribute/2 returns data attribute", %{frame: frame} do
      assert {:ok, "input-1"} =
               Frame.get_attribute(frame.guid, selector: "#text-input", name: "data-testid", timeout: @timeout)
    end

    test "get_attribute/2 returns nil for missing attribute", %{frame: frame} do
      assert {:ok, nil} =
               Frame.get_attribute(frame.guid, selector: "#text-input", name: "data-nonexistent", timeout: @timeout)
    end

    test "input_value/2 returns input value", %{frame: frame} do
      assert {:ok, "hello"} = Frame.input_value(frame.guid, selector: "#text-input", timeout: @timeout)
    end

    test "input_value/2 returns select value", %{frame: frame} do
      assert {:ok, "a"} = Frame.input_value(frame.guid, selector: "#my-select", timeout: @timeout)
    end

    test "text_content/2 returns text content", %{frame: frame} do
      assert {:ok, "Some text content"} = Frame.text_content(frame.guid, selector: "#text-div", timeout: @timeout)
    end

    test "inner_text/2 returns inner text", %{frame: frame} do
      assert {:ok, text} = Frame.inner_text(frame.guid, selector: "#inner-div", timeout: @timeout)
      assert text =~ "Inner"
    end
  end

  describe "focus" do
    test "focus/2 focuses an element", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            document.body.innerHTML = '<input id="my-input" type="text" />';
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      assert {:ok, _} = Frame.focus(frame.guid, selector: "#my-input", timeout: @timeout)

      {:ok, focused_id} =
        Frame.evaluate(frame.guid,
          expression: "() => document.activeElement.id",
          is_function: true,
          timeout: @timeout
        )

      assert focused_id == "my-input"
    end
  end

  describe "dispatch_event" do
    test "dispatch_event/2 dispatches a click event", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            document.body.innerHTML = '<div id="target">Click me</div>';
            window.__clicked = false;
            document.getElementById('target').addEventListener('click', () => { window.__clicked = true; });
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      assert {:ok, _} =
               Frame.dispatch_event(frame.guid, selector: "#target", type: "click", timeout: @timeout)

      {:ok, clicked} =
        Frame.evaluate(frame.guid,
          expression: "() => window.__clicked",
          is_function: true,
          timeout: @timeout
        )

      assert clicked == true
    end
  end

  describe "wait_for_function" do
    test "wait_for_function/2 resolves when expression becomes truthy", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: """
          () => {
            window.__ready = false;
            setTimeout(() => { window.__ready = true; }, 100);
          }
          """,
          is_function: true,
          timeout: @timeout
        )

      assert {:ok, %{handle: %{guid: _}}} =
               Frame.wait_for_function(frame.guid,
                 expression: "() => window.__ready",
                 is_function: true,
                 timeout: @timeout
               )
    end

    test "wait_for_function/2 returns a handle for the expression value", %{frame: frame} do
      {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)

      {:ok, _} =
        Frame.evaluate(frame.guid,
          expression: "() => { window.__counter = 42; }",
          is_function: true,
          timeout: @timeout
        )

      assert {:ok, %{handle: %{guid: _}}} =
               Frame.wait_for_function(frame.guid,
                 expression: "() => window.__counter",
                 is_function: true,
                 timeout: @timeout
               )
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
