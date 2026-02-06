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
