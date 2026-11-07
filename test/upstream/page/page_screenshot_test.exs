defmodule PlaywrightEx.Page.PageScreenshotTest do
  @upstream "tests/page/page-screenshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import PlaywrightEx.Utils
  import PlaywrightEx.UpstreamSnapshot

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer

  @moduletag :page

  @caret_content """
  <!-- Refer to stylesheet from other origin. Accessing this
       stylesheet rules will throw.
  -->
  <link rel=stylesheet href="CROSS_PROCESS_PREFIX/injectedstyle.css">
  <!-- make life harder: define caret color in stylesheet -->
  <style>
    div {
      caret-color: #000 !important;
    }
  </style>
  <div contenteditable="true"></div>
  """

  describe "page screenshot" do
    # it.skip(browserName === 'firefox' && !headless)  -- headless here
    # it.skip(isAndroid)  -- not Android

    test "SS-001 should work @smoke", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot = Page.screenshot!(page)
      to_match_snapshot(screenshot, "screenshot-sanity.png")
    end

    test "SS-002 should not capture blinking caret by default", %{page: page, server: server} do
      Page.set_content!(page, String.replace(@caret_content, "CROSS_PROCESS_PREFIX", server.cross_process_prefix))
      div = Page.locator(page, "div")
      Locator.type!(div, "foo bar")
      screenshot = Locator.screenshot!(div)

      for _ <- 0..9 do
        # Caret blinking time is set to 500ms.
        # Try to capture variety of screenshots to make
        # sure we don't capture blinking caret.
        Process.sleep(150)
        new_screenshot = Locator.screenshot!(div)
        assert new_screenshot == screenshot
      end
    end

    @tag skip:
           if(@browser_name == "firefox",
             do: "upstream skip: browser-level screenshot API in firefox does not capture caret"
           )
    test "SS-003 should capture blinking caret if explicitly asked for",
         %{page: page, server: server} do
      # it.skip(browserName === 'firefox', 'browser-level screenshot API in firefox does not capture caret')
      Page.set_content!(page, String.replace(@caret_content, "CROSS_PROCESS_PREFIX", server.cross_process_prefix))
      div = Page.locator(page, "div")
      Locator.type!(div, "foo bar")
      screenshot = Locator.screenshot!(div)

      # Caret blinking time is set to 500ms.
      # Try to capture variety of screenshots to make
      # sure we capture blinking caret.
      has_different_screenshots =
        Enum.reduce_while(0..9, false, fn _, _ ->
          Process.sleep(150)
          new_screenshot = Locator.screenshot!(div, caret: :initial)
          if new_screenshot != screenshot, do: {:halt, true}, else: {:cont, false}
        end)

      assert has_different_screenshots
    end

    test "SS-004 should capture blinking caret in shadow dom", %{page: page} do
      Page.add_script_tag!(page,
        content: """
        class CustomElementContainer extends HTMLElement {
          #shadowRoot;
          constructor() {
            super();
            this.#shadowRoot = this.attachShadow({ mode: 'open' });
            this.#shadowRoot.innerHTML = '<custom-element-input-wrapper><input type="text"/></custom-element-input-wrapper>';
          }
        }
        class CustomElementInputWrapper extends HTMLElement {
          #shadowRoot;
          constructor() {
            super();
            this.#shadowRoot = this.attachShadow({ mode: 'open' });
            this.#shadowRoot.innerHTML = '<style>:host { all: initial; }</style><slot/>';
          }
        }
        customElements.define('custom-element-input-wrapper', CustomElementInputWrapper);
        customElements.define('custom-element-container', CustomElementContainer);

        const container = document.createElement('custom-element-container');
        document.body.appendChild(container);
        """
      )

      input = Page.locator(page, "input")
      # Upstream to-do: click fails in webkit
      Locator.focus!(input)

      screenshot = Locator.screenshot!(input)

      has_different_screenshots =
        Enum.reduce_while(0..9, false, fn _, _ ->
          # Caret blinking time is set to 500ms.
          # Try to capture variety of screenshots to make
          # sure we capture blinking caret.
          Process.sleep(150)
          new_screenshot = Locator.screenshot!(input, caret: :hide)
          if new_screenshot != screenshot, do: {:halt, true}, else: {:cont, false}
        end)

      refute has_different_screenshots
    end

    test "SS-005 should clip rect", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot = Page.screenshot!(page, clip: %{x: 50, y: 100, width: 150, height: 100})
      to_match_snapshot(screenshot, "screenshot-clip-rect.png")
    end

    test "SS-006 should clip rect with fullPage", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      Page.evaluate!(page, "() => window.scrollBy(150, 200)")
      screenshot = Page.screenshot!(page, full_page: true, clip: %{x: 50, y: 100, width: 150, height: 100})
      to_match_snapshot(screenshot, "screenshot-clip-rect.png")
    end

    test "SS-007 should clip elements to the viewport", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot = Page.screenshot!(page, clip: %{x: 50, y: 450, width: 1000, height: 100})
      to_match_snapshot(screenshot, "screenshot-offscreen-clip.png")
    end

    test "SS-008 should throw on clip outside the viewport", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      {:error, screenshot_error} = Page.screenshot(page, clip: %{x: 50, y: 650, width: 100, height: 100})
      assert Exception.message(screenshot_error) =~ "Clipped area is either empty or outside the resulting image"
    end

    test "SS-009 should throw on a negative clip size", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      {:error, screenshot_error} = Page.screenshot(page, clip: %{x: 50, y: 50, width: -100, height: 100})
      assert Exception.message(screenshot_error) =~ "Expected options.clip.width to be greater than 0"
    end

    test "SS-010 should run in parallel", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")

      promises =
        for i <- 0..2 do
          Task.async(fn -> Page.screenshot!(page, clip: %{x: 50 * i, y: 0, width: 50, height: 50}) end)
        end

      screenshots = Task.await_many(promises, :infinity)
      to_match_snapshot(Enum.at(screenshots, 1), "grid-cell-1.png")
    end

    test "SS-011 should take fullPage screenshots", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot = Page.screenshot!(page, full_page: true)
      to_match_snapshot(screenshot, "screenshot-grid-fullpage.png")
    end

    test "SS-012 should take fullPage screenshots and mask elements outside of it", %{page: page, server: server} do
      # annotation: issue https://github.com/microsoft/playwright/issues/30770
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot = Page.screenshot!(page, full_page: true, mask: [Locator.nth(Page.locator(page, ".box"), 144)])
      to_match_snapshot(screenshot, "screenshot-grid-fullpage-mask-outside-viewport.png")
    end

    test "SS-013 should restore viewport after fullPage screenshot", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot = Page.screenshot!(page, full_page: true)
      assert is_binary(screenshot)
      verify_viewport(page, 500, 500)
    end

    test "SS-014 should allow transparency", %{page: page} do
      expected_failure(@browser_name == "firefox", fn ->
        # it.fail(browserName === 'firefox' || isBidi)  -- see the tag; isBidi is false here
        Page.set_viewport_size!(page, %{width: 300, height: 300})

        Page.set_content!(page, """
        <style>
          body { margin: 0 }
          div { width: 300px; height: 100px; }
        </style>
        <div style="background:black"></div>
        <div style="background:white"></div>
        <div style="background:transparent"></div>
        """)

        screenshot = Page.screenshot!(page, omit_background: true)

        to_match_snapshot(screenshot, "transparent.png")
      end)
    end

    test "SS-015 should render white background on jpeg file", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 300, height: 300})
      Page.goto!(page, server.empty_page)
      screenshot = Page.screenshot!(page, omit_background: true, type: :jpeg)
      to_match_snapshot(screenshot, "white.jpg")
    end

    test "SS-016 should produce a valid webp screenshot", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 300, height: 300})
      Page.goto!(page, server.empty_page)
      Page.evaluate!(page, "() => (document.body.style.background = 'rgb(255, 0, 0)')")
      screenshot = Page.screenshot!(page, type: :webp)
      to_match_snapshot(screenshot, "red.webp")
    end

    @tag :tmp_dir
    test "SS-017 path option should detect webp", %{page: page, server: server, tmp_dir: tmp_dir} do
      Page.set_viewport_size!(page, %{width: 300, height: 300})
      Page.goto!(page, server.empty_page)
      Page.evaluate!(page, "() => (document.body.style.background = 'rgb(255, 0, 0)')")
      output_path = Path.join(tmp_dir, "screenshot.webp")
      screenshot = Page.screenshot!(page, path: output_path)
      to_match_snapshot(File.read!(output_path), "red.webp")
      to_match_snapshot(screenshot, "red.webp")
    end

    test "SS-018 quality option should work for webp", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/grid.html")
      low_quality = Page.screenshot!(page, type: :webp, quality: 0)
      high_quality = Page.screenshot!(page, type: :webp, quality: 100)
      assert byte_size(low_quality) < byte_size(high_quality)
    end

    test "SS-019 webp screenshots should be lossless by default", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/grid.html")
      assert lossless_webp?(Page.screenshot!(page, type: :webp)) == true
      assert lossless_webp?(Page.screenshot!(page, type: :webp, quality: 80)) == false
    end

    test "SS-020 should allow transparency with webp", %{page: page} do
      expected_failure(@browser_name == "firefox", fn ->
        # it.skip(isBidi)  -- isBidi is false here
        # it.fail(browserName === 'firefox')  -- see the tag
        Page.set_viewport_size!(page, %{width: 300, height: 300})

        Page.set_content!(page, """
        <style>
          body { margin: 0 }
          div { width: 300px; height: 100px; }
        </style>
        <div style="background:black"></div>
        <div style="background:white"></div>
        <div style="background:transparent"></div>
        """)

        screenshot = Page.screenshot!(page, omit_background: true, type: :webp)
        %{width: width, height: height, data: data} = decode_image(:webp, screenshot)
        assert width == 300
        assert height == 300
        pixel = fn x, y -> :binary.bin_to_list(data, (y * width + x) * 4, 4) end
        assert pixel.(150, 50) == [0, 0, 0, 255]
        assert pixel.(150, 150) == [255, 255, 255, 255]
        assert Enum.at(pixel.(150, 250), 3) == 0
      end)
    end

    test "SS-021 quality option should throw for webp when out of range", %{page: page} do
      {:error, error} = Page.screenshot(page, type: :webp, quality: 101)
      assert Exception.message(error) =~ "Expected options.quality to be between 0 and 100"
    end

    test "SS-022 should work with odd clip size on Retina displays", %{page: page} do
      # it.skip(isElectron)  -- not Electron
      screenshot = Page.screenshot!(page, clip: %{x: 0, y: 0, width: 11, height: 11})
      to_match_snapshot(screenshot, "screenshot-clip-odd-size.png")
    end

    test "SS-023 should work for canvas", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/screenshots/canvas.html")
      screenshot = Page.screenshot!(page)
      # Allow 4 corners to be rendered differently on various platforms/browsers.
      to_match_snapshot(screenshot, "screenshot-canvas.png", %{maxDiffPixels: 4})
    end

    test "SS-024 should capture canvas changes", %{page: page} do
      # it.skip(isElectron)  -- not Electron
      Page.goto!(page, "data:text/html,<canvas></canvas>")

      Page.evaluate!(page, """
      () => {
        const canvas = document.querySelector('canvas');
        canvas.width = 600;
        canvas.height = 600;
      }
      """)

      add_line = fn step ->
        Page.evaluate!(
          page,
          """
          n => {
            const canvas = document.querySelector('canvas');
            const ctx = canvas.getContext('2d');
            ctx.lineWidth = 1;
            ctx.beginPath();
            ctx.moveTo(0, n * 100);
            ctx.lineTo(300, n * 100);
            ctx.stroke();
          }
          """,
          step
        )
      end

      for i <- 0..2 do
        add_line.(i)
        # With the slight delay WebKit stops reflecting changes in the screenshots on macOS.
        Process.sleep(100)
        screenshot = Page.screenshot!(page)
        to_match_snapshot(screenshot, "canvas-changes-#{i}.png")
      end
    end

    @tag skip:
           (cond do
              @browser_name == "webkit" and match?({:unix, :darwin}, :os.type()) and
                  String.starts_with?(to_string(:erlang.system_info(:system_architecture)), "x86_64") ->
                "upstream skip: WebGL is not available on Intel macOS - https://bugs.webkit.org/show_bug.cgi?id=278277"

              @browser_name == "firefox" and match?({:unix, :linux}, :os.type()) and
                  System.get_env("DISPLAY") in [nil, ""] ->
                "env: Linux firefox WebGL needs a DISPLAY (upstream CI runs under xvfb-run)"

              true ->
                nil
            end)
    test "SS-025 should work for webgl", %{page: page, server: server} do
      # it.skip(isElectron)  -- not Electron
      Page.set_viewport_size!(page, %{width: 640, height: 480})
      Page.goto!(page, server.prefix <> "/screenshots/webgl.html")
      screenshot = Page.screenshot!(page)
      to_match_snapshot(screenshot, "screenshot-webgl.png")
    end

    test "SS-026 should work for translateZ", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/screenshots/translateZ.html")
      screenshot = Page.screenshot!(page)
      to_match_snapshot(screenshot, "screenshot-translateZ.png")
    end

    test "SS-027 should work while navigating", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/redirectloop1.html")

      for _ <- 0..9 do
        screenshot =
          case Page.screenshot(page, full_page: true) do
            {:ok, screenshot} ->
              screenshot

            {:error, e} ->
              if !String.contains?(Exception.message(e), "Cannot take a screenshot while page is navigating"),
                do: raise(e)

              ""
          end

        assert is_binary(screenshot)
      end
    end

    test "SS-028 should work with iframe in shadow", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid-iframe-in-shadow.html")
      to_match_snapshot(Page.screenshot!(page), "screenshot-iframe.png")
    end

    @tag :tmp_dir
    test "SS-029 path option should work", %{page: page, server: server, tmp_dir: tmp_dir} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      output_path = Path.join(tmp_dir, "screenshot.png")
      Page.screenshot!(page, path: output_path)
      to_match_snapshot(File.read!(output_path), "screenshot-sanity.png")
    end

    @tag :tmp_dir
    test "SS-030 path option should create subdirectories", %{page: page, server: server, tmp_dir: tmp_dir} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      output_path = Path.join([tmp_dir, "these", "are", "directories", "screenshot.png"])
      Page.screenshot!(page, path: output_path)
      to_match_snapshot(File.read!(output_path), "screenshot-sanity.png")
    end

    @tag :tmp_dir
    test "SS-031 path option should detect jpeg", %{page: page, server: server, tmp_dir: tmp_dir} do
      Page.set_viewport_size!(page, %{width: 300, height: 300})
      Page.goto!(page, server.empty_page)
      output_path = Path.join(tmp_dir, "screenshot.jpg")
      screenshot = Page.screenshot!(page, omit_background: true, path: output_path)
      to_match_snapshot(File.read!(output_path), "white.jpg")
      to_match_snapshot(screenshot, "white.jpg")
    end

    test "SS-032 path option should throw for unsupported mime type", %{page: page} do
      {:error, error} = Page.screenshot(page, path: "file.txt")
      assert Exception.message(error) =~ ~s(path: unsupported mime type "text/plain")
    end

    test "SS-033 quality option should throw for png", %{page: page} do
      {:error, error} = Page.screenshot(page, quality: 10)
      assert Exception.message(error) =~ "options.quality is unsupported for the png"
    end

    test "SS-034 zero quality option should throw for png", %{page: page} do
      {:error, error} = Page.screenshot(page, quality: 0, type: :png)
      assert Exception.message(error) =~ "options.quality is unsupported for the png"
    end

    test "SS-035 quality option should work for jpeg", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/grid.html")
      zero_quality = Page.screenshot!(page, type: :jpeg, quality: 0)
      high_quality = Page.screenshot!(page, type: :jpeg, quality: 100)
      assert byte_size(zero_quality) < byte_size(high_quality)
    end

    @tag :tmp_dir
    test "SS-036 should prefer type over extension", %{page: page, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "file.png")
      buffer = Page.screenshot!(page, path: output_path, type: :jpeg)
      assert binary_part(buffer, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test "SS-037 should not issue resize event", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/grid.html")
      test = self()

      Page.expose_function!(page, "resize", fn ->
        send(test, :resize_triggered)
        nil
      end)

      Page.evaluate!(page, "() => { window.addEventListener('resize', () => window.resize()); }")
      Page.screenshot!(page)
      refute_received :resize_triggered
    end

    test "SS-038 should work with Array deleted", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      Page.evaluate!(page, "() => delete window.Array")
      screenshot = Page.screenshot!(page, full_page: true)
      to_match_snapshot(screenshot, "screenshot-grid-fullpage.png")
    end

    # it.slow()
    @tag timeout: @slow_timeout
    test "SS-039 should take fullPage screenshots during navigation", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      reload_several_times = Task.async(fn -> for _ <- 1..5, do: Page.reload!(page) end)
      screenshot_several_times = Task.async(fn -> for _ <- 1..5, do: Page.screenshot!(page, full_page: true) end)
      Task.await_many([reload_several_times, screenshot_several_times], :infinity)
    end
  end

  # Nested upstream: describe('page screenshot') > describe('mask option').
  describe "page screenshot mask option" do
    test "SS-040 should work", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")

      to_match_snapshot(
        Page.screenshot!(page, mask: [Locator.nth(Page.locator(page, "div"), 5)]),
        "mask-should-work.png"
      )
    end

    test "SS-041 should work with locator", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      body_locator = Page.locator(page, "body")

      to_match_snapshot(
        Locator.screenshot!(body_locator, mask: [Locator.nth(Page.locator(page, "div"), 5)]),
        "mask-should-work-with-locator.png"
      )
    end

    test "SS-042 should work with elementhandle", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      body_handle = Page.query_selector!(page, "body")

      to_match_snapshot(
        ElementHandle.screenshot!(body_handle, mask: [Locator.nth(Page.locator(page, "div"), 5)]),
        "mask-should-work-with-elementhandle.png"
      )
    end

    test "SS-043 should mask multiple elements", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")

      to_match_snapshot(
        Page.screenshot!(page,
          mask: [
            Locator.nth(Page.locator(page, "div"), 5),
            Locator.nth(Page.locator(page, "div"), 12)
          ]
        ),
        "should-mask-multiple-elements.png"
      )
    end

    test "SS-044 should mask inside iframe", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      attach_frame(page, "frame1", server.prefix <> "/grid.html")
      Page.add_style_tag!(page, content: "iframe { border: none; }")

      to_match_snapshot(
        Page.screenshot!(page,
          mask: [
            Locator.nth(Page.locator(page, "div"), 5),
            page |> Page.frame_locator("#frame1") |> FrameLocator.locator("div") |> Locator.nth(12)
          ]
        ),
        "should-mask-inside-iframe.png"
      )
    end

    test "SS-045 should mask in parallel", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      attach_frame(page, "frame1", server.prefix <> "/grid.html")
      attach_frame(page, "frame2", server.prefix <> "/grid.html")
      Page.add_style_tag!(page, content: "iframe { border: none; }")

      screenshots =
        Task.await_many(
          [
            Task.async(fn ->
              Page.screenshot!(page,
                mask: [page |> Page.frame_locator("#frame1") |> FrameLocator.locator("div") |> Locator.nth(1)]
              )
            end),
            Task.async(fn ->
              Page.screenshot!(page,
                mask: [page |> Page.frame_locator("#frame2") |> FrameLocator.locator("div") |> Locator.nth(3)]
              )
            end)
          ],
          :infinity
        )

      to_match_snapshot(Enum.at(screenshots, 0), "should-mask-in-parallel-1.png")
      to_match_snapshot(Enum.at(screenshots, 1), "should-mask-in-parallel-2.png")
    end

    test "SS-046 should remove mask after screenshot", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot1 = Page.screenshot!(page)
      Page.screenshot!(page, mask: [Locator.nth(Page.locator(page, "div"), 1)])
      screenshot2 = Page.screenshot!(page)
      assert screenshot1 == screenshot2
    end

    test "SS-047 should work when subframe has stalled navigation", %{page: page, server: server} do
      test = self()
      # Stalling subframe.
      Page.route!(page, "**/subframe.html", fn route -> send(test, {:route, route}) end)

      Page.goto!(page, server.empty_page)
      done = Runtime.Promise.async(fn -> Page.set_content!(page, "<iframe src='/subframe.html'></iframe>") end)
      assert_receive {:route, route}, 5000

      Page.screenshot!(page, mask: [Page.locator(page, "non-existent")])
      Route.fulfill!(route, body: "")
      Runtime.Promise.await(done)
    end

    test "SS-048 should work when subframe used document.open after a weird url", %{page: page, server: server} do
      Page.goto!(page, server.empty_page)

      Page.evaluate!(page, """
      () => {
        const iframe = document.createElement('iframe');
        iframe.src = 'javascript:hi';
        document.body.appendChild(iframe);
        iframe.contentDocument.open();
        iframe.contentDocument.write('Hello');
        iframe.contentDocument.close();
      }
      """)

      Page.screenshot!(page, mask: [Page.locator(page, "non-existent")])
    end

    test "SS-049 should work when mask color is not pink #F0F", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")

      to_match_snapshot(
        Page.screenshot!(page, mask: [Locator.nth(Page.locator(page, "div"), 5)], mask_color: "#00FF00"),
        "mask-color-should-work.png"
      )
    end

    test "SS-050 should hide elements based on attr", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")

      page
      |> Page.locator("div")
      |> Locator.nth(5)
      |> Locator.evaluate!("element => { element.setAttribute('data-test-screenshot', 'hide'); }")

      to_match_snapshot(
        Page.screenshot!(page,
          style: """
          [data-test-screenshot="hide"] {
            visibility: hidden;
          }
          """
        ),
        "hide-should-work.png"
      )

      visibility =
        page |> Page.locator("div") |> Locator.nth(5) |> Locator.evaluate!("element => element.style.visibility")

      assert visibility == ""
    end

    test "SS-051 should remove elements based on attr", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")

      page
      |> Page.locator("div")
      |> Locator.nth(5)
      |> Locator.evaluate!("element => { element.setAttribute('data-test-screenshot', 'remove'); }")

      to_match_snapshot(
        Page.screenshot!(page,
          style: """
          [data-test-screenshot="remove"] {
            display: none;
          }
          """
        ),
        "remove-should-work.png"
      )

      display = page |> Page.locator("div") |> Locator.nth(5) |> Locator.evaluate!("element => element.style.display")
      assert display == ""
    end
  end

  describe "page screenshot animations" do
    test "SS-052 should not capture infinite css animation", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/rotate-z.html")
      div = Page.locator(page, "div")
      screenshot = Locator.screenshot!(div, animations: :disabled)

      for _ <- 0..9 do
        rafraf(page)
        new_screenshot = Locator.screenshot!(div, animations: :disabled)
        assert new_screenshot == screenshot
      end
    end

    test "SS-053 should not capture pseudo element css animation", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/rotate-pseudo.html")
      div = Page.locator(page, "div")
      screenshot = Locator.screenshot!(div, animations: :disabled)

      for _ <- 0..9 do
        rafraf(page)
        new_screenshot = Locator.screenshot!(div, animations: :disabled)
        assert new_screenshot == screenshot
      end
    end

    test "SS-054 should not capture css animations in shadow DOM", %{page: page, server: server} do
      # it.skip(isAndroid, 'Different viewport')
      Page.goto!(page, server.prefix <> "/rotate-z-shadow-dom.html")
      screenshot = Page.screenshot!(page, animations: :disabled)

      for _ <- 0..3 do
        rafraf(page)
        new_screenshot = Page.screenshot!(page, animations: :disabled)
        assert new_screenshot == screenshot
      end
    end

    test "SS-055 should stop animations that happen right before screenshot"

    test "SS-056 should resume infinite animations", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/rotate-z.html")
      Page.screenshot!(page, animations: :disabled)
      buffer1 = Page.screenshot!(page)
      rafraf(page)
      buffer2 = Page.screenshot!(page)
      assert compare_pngs(buffer1, buffer2, %{maxDiffPixels: 50}) != nil
    end

    test "SS-057 should not capture infinite web animations", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/web-animation.html")
      div = Page.locator(page, "div")
      screenshot = Locator.screenshot!(div, animations: :disabled)

      for _ <- 0..9 do
        rafraf(page)
        new_screenshot = Locator.screenshot!(div, animations: :disabled)
        assert new_screenshot == screenshot
      end

      # Should resume infinite web animation.
      buffer1 = Page.screenshot!(page)
      rafraf(page)
      buffer2 = Page.screenshot!(page)
      assert compare_pngs(buffer1, buffer2, %{maxDiffPixels: 50}) != nil
    end

    test "SS-058 should fire transitionend for finite transitions", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/css-transition.html")
      div = Page.locator(page, "div")

      Locator.evaluate!(div, """
      el => {
        el.addEventListener('transitionend', () => window['__TRANSITION_END'] = true, false);
      }
      """)

      # it.step('make sure transition is actually running')
      screenshot1 = Page.screenshot!(page)
      rafraf(page)
      screenshot2 = Page.screenshot!(page)
      assert screenshot1 != screenshot2

      # Make a screenshot that finishes all finite animations.
      screenshot1 = Locator.screenshot!(div, animations: :disabled)
      rafraf(page)
      # Make sure finite transition is not restarted.
      screenshot2 = Locator.screenshot!(div, animations: :allow)
      assert screenshot1 == screenshot2

      assert Page.evaluate!(page, "() => window['__TRANSITION_END']") == true
    end

    test "SS-059 should capture screenshots after layoutchanges in transitionend event", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/css-transition.html")
      div = Page.locator(page, "div")

      Locator.evaluate!(div, """
      el => {
        el.addEventListener('transitionend', () => {
          const time = window.builtins.Date.now();
          // Block main thread for 200ms, emulating heavy layout.
          while (window.builtins.Date.now() - time < 200) {}
          const h1 = document.createElement('h1');
          h1.textContent = 'woof-woof';
          document.body.append(h1);
        }, false);
      }
      """)

      # it.step('make sure transition is actually running')
      screenshot1 = Page.screenshot!(page)
      rafraf(page)
      screenshot2 = Page.screenshot!(page)
      assert screenshot1 != screenshot2

      # 1. Make a screenshot that finishes all finite animations
      #    and triggers layout.
      screenshot1 = Page.screenshot!(page, animations: :disabled)

      # 2. Make a second screenshot after h1 is on screen.
      Expect.to_be_visible!(Page.locator(page, "h1"))
      Expect.to_have_text!(Page.locator(page, "h1"), "woof-woof")
      screenshot2 = Page.screenshot!(page)

      # 3. Make sure both screenshots are equal, meaning that
      #    first screenshot actually was taken after transitionend
      #    changed layout.
      assert screenshot1 == screenshot2
    end

    test "SS-060 should not change animation with playbackRate equal to 0", %{page: page, server: server} do
      # it.skip(isAndroid, 'Different viewport')
      Page.goto!(page, server.prefix <> "/rotate-z.html")

      Page.evaluate!(page, """
      async () => {
        window.animation = document.getAnimations()[0];
        await window.animation.ready;
        window.animation.updatePlaybackRate(0);
        await window.animation.ready;
        window.animation.currentTime = 500;
      }
      """)

      screenshot1 = Page.screenshot!(page, animations: :disabled)
      rafraf(page)
      screenshot2 = Page.screenshot!(page, animations: :disabled)
      assert screenshot1 == screenshot2

      assert Page.evaluate!(page, """
             () => ({
               playbackRate: window.animation.playbackRate,
               currentTime: window.animation.currentTime,
             })
             """) == %{"playbackRate" => 0, "currentTime" => 500}
    end

    test "SS-061 should trigger particular events for css transitions", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/css-transition.html")
      div = Page.locator(page, "div")

      Locator.evaluate!(div, """
      async el => {
        window._EVENTS = [];
        el.addEventListener('transitionend', () => {
          window._EVENTS.push('transitionend');
          console.log('transitionend');
        }, false);
        const animation = el.getAnimations()[0];
        animation.oncancel = () => window._EVENTS.push('oncancel');
        animation.onfinish = () => window._EVENTS.push('onfinish');
        animation.onremove = () => window._EVENTS.push('onremove');
        await animation.ready;
      }
      """)

      console = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "transitionend"))
      Page.screenshot!(page, animations: :disabled)
      PlaywrightEx.Promise.await!(console)
      assert Page.evaluate!(page, "() => window._EVENTS") == ["onfinish", "transitionend"]
    end

    test "SS-062 should trigger particular events for INfinite css animation", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/rotate-z.html")
      div = Page.locator(page, "div")

      Locator.evaluate!(div, """
      async el => {
        window._EVENTS = [];
        el.addEventListener('animationcancel', () => {
          window._EVENTS.push('animationcancel');
          console.log('animationcancel');
        }, false);
        const animation = el.getAnimations()[0];
        animation.oncancel = () => window._EVENTS.push('oncancel');
        animation.onfinish = () => window._EVENTS.push('onfinish');
        animation.onremove = () => window._EVENTS.push('onremove');
        await animation.ready;
      }
      """)

      console = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "animationcancel"))
      Page.screenshot!(page, animations: :disabled)
      PlaywrightEx.Promise.await!(console)
      assert Page.evaluate!(page, "() => window._EVENTS") == ["oncancel", "animationcancel"]
    end

    test "SS-063 should trigger particular events for finite css animation", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/rotate-z.html")
      div = Page.locator(page, "div")

      Locator.evaluate!(div, """
      async el => {
        window._EVENTS = [];
        // Make CSS animation to be finite.
        el.style.setProperty('animation-iteration-count', '1000');
        el.addEventListener('animationend', () => {
          window._EVENTS.push('animationend');
          console.log('animationend');
        }, false);
        const animation = el.getAnimations()[0];
        animation.oncancel = () => window._EVENTS.push('oncancel');
        animation.onfinish = () => window._EVENTS.push('onfinish');
        animation.onremove = () => window._EVENTS.push('onremove');
        await animation.ready;
      }
      """)

      # Ensure CSS animation is finite.
      assert Locator.evaluate!(
               div,
               "async el => Number.isFinite(el.getAnimations()[0].effect.getComputedTiming().endTime)"
             ) == true

      console = Page.wait_for_event(page, :console, &(ConsoleMessage.text(&1) == "animationend"))
      Page.screenshot!(page, animations: :disabled)
      PlaywrightEx.Promise.await!(console)
      assert Page.evaluate!(page, "() => window._EVENTS") == ["onfinish", "animationend"]
    end

    test "SS-064 should wait for fonts to load", %{page: page, server: server, asset: asset} do
      # it.fixme(isWindows)  -- not Windows
      # it.skip(isAndroid)  -- not Android
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      test = self()

      # Stall font loading.
      TestServer.set_route(server, "/webfont/iconfont.woff2", fn conn ->
        send(test, {:font_request, self()})

        receive do
          :serve -> TestServer.serve_file(server, conn, asset.("webfont/iconfont.woff2"))
        end
      end)

      # 'load' will not happen if webfont is pending
      Page.goto!(page, server.prefix <> "/webfont/webfont.html", wait_until: :domcontentloaded)

      # Make sure screenshot times out while webfont is stalled.
      {:error, error} = Page.screenshot(page, timeout: 200)
      assert Exception.message(error) =~ "waiting for fonts to load..."
      assert Exception.message(error) =~ "Timeout 200ms exceeded"

      assert_receive {:font_request, font_request}
      send(font_request, :serve)
      icons_screenshot = Page.screenshot!(page)
      to_match_snapshot(icons_screenshot, "screenshot-web-font.png", %{maxDiffPixels: 50})
    end
  end

  test "SS-065 should throw if screenshot size is too large", %{page: page, browser_name: browser_name} do
    # isBidi is false here: no WebDriver BiDi
    is_mac = match?({:unix, :darwin}, :os.type())
    max_size = 32_767

    Page.set_content!(
      page,
      "<style>body {margin: 0; padding: 0;}</style><div style='min-height: #{max_size}px; background: red;'></div>"
    )

    result = Page.screenshot!(page, full_page: true)
    assert result

    Page.set_content!(
      page,
      "<style>body {margin: 0; padding: 0;}</style><div style='min-height: #{max_size + 1}px; background: red;'></div>"
    )

    exception = Page.screenshot(page, full_page: true)

    if browser_name == "firefox" or (browser_name == "webkit" and !is_mac) do
      assert {:error, e} = exception
      assert Exception.message(e) =~ "Cannot take screenshot larger than 32767"
    end
  end

  @tag :tmp_dir
  @tag skip: if(@browser_name == "webkit", do: "upstream fixme: webkit")
  test "SS-066 page screenshot should capture css transform", %{
    page: page,
    browser_name: browser_name,
    tmp_dir: tmp_dir
  } do
    # it.fixme(browserName === 'webkit')
    # it.skip(isElectron || isAndroid, 'Returns screenshot of a different size.')
    Page.set_content!(page, """
    <style>
    .container {
      width: 150px;
      height: 150px;
      margin: 75px 0 0 75px;
      border: none;
    }

    .cube {
      width: 100%;
      height: 100%;
      perspective: 550px;
      perspective-origin: 150% 150%;
    }

    .face {
      display: block;
      position: absolute;
      width: 100px;
      height: 100px;
      border: none;
    }

    .right {
      background: rgba(196, 0, 0, 0.7);
      transform: rotateY(70deg);
    }

    </style>
    <div class="container">
      <div class="cube showbf">
        <div class="face right"></div>
      </div>
    </div>
    """)

    Expect.to_have_screenshot!(page,
      path: upstream_snapshot(tmp_dir, "page-screenshot-should-capture-css-transform-1", browser_name)
    )
  end

  @tag :tmp_dir
  test "SS-067 should capture css box-shadow", %{page: page, browser_name: browser_name, tmp_dir: tmp_dir} do
    # it.skip(isElectron || isAndroid, 'Returns screenshot of a different size.')
    Page.set_content!(page, ~s(<div style="box-shadow: red 10px 10px 10px; width: 50px; height: 50px;"></div>))
    Expect.to_have_screenshot!(page, path: upstream_snapshot(tmp_dir, "should-capture-css-box-shadow-1", browser_name))
  end

  # utils.isLosslessWebp (packages/utils/webp/webp.ts)
  defp lossless_webp?(<<"RIFF", _size::binary-size(4), "WEBP", chunks::binary>>), do: lossless_webp_chunks?(chunks)
  defp lossless_webp?(_buffer), do: false

  defp lossless_webp_chunks?(<<"VP8L", _::binary>>), do: true
  defp lossless_webp_chunks?(<<"VP8 ", _::binary>>), do: false

  defp lossless_webp_chunks?(<<_fourcc::binary-size(4), size::little-32, rest::binary>>) do
    # Skip this chunk (8-byte header + payload, padded to an even size).
    skip = size + Bitwise.band(size, 1)
    if byte_size(rest) >= skip, do: lossless_webp_chunks?(binary_part(rest, skip, byte_size(rest) - skip)), else: false
  end

  defp lossless_webp_chunks?(_rest), do: false

  # The runner resolves the auto-generated snapshot name to the spec's snapshot; failures write next to the copy.
  defp upstream_snapshot(tmp_dir, name, browser_name) do
    path = Path.join(tmp_dir, name <> ".png")

    File.cp!(
      Path.join(
        PlaywrightEx.Upstream.dir(),
        "tests/page/page-screenshot.spec.ts-snapshots/#{name}-#{browser_name}.png"
      ),
      path
    )

    path
  end
end
