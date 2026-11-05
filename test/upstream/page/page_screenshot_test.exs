defmodule PlaywrightEx.Page.PageScreenshotTest do
  @upstream "tests/page/page-screenshot.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  import PlaywrightEx.Utils

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route

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

    @tag skip: "not ported: toMatchSnapshot"
    test "should work @smoke"

    test "should not capture blinking caret by default", %{page: page, server: server} do
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
    test "should capture blinking caret if explicitly asked for",
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

    test "should capture blinking caret in shadow dom", %{page: page} do
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

    @tag skip: "not ported: toMatchSnapshot"
    test "should clip rect"

    @tag skip: "not ported: toMatchSnapshot"
    test "should clip rect with fullPage"

    @tag skip: "not ported: toMatchSnapshot"
    test "should clip elements to the viewport"

    test "should throw on clip outside the viewport", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      {:error, screenshot_error} = Page.screenshot(page, clip: %{x: 50, y: 650, width: 100, height: 100})
      assert Exception.message(screenshot_error) =~ "Clipped area is either empty or outside the resulting image"
    end

    test "should throw on a negative clip size", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      {:error, screenshot_error} = Page.screenshot(page, clip: %{x: 50, y: 50, width: -100, height: 100})
      assert Exception.message(screenshot_error) =~ "Expected options.clip.width to be greater than 0"
    end

    @tag skip: "not ported: toMatchSnapshot"
    test "should run in parallel"

    @tag skip: "not ported: toMatchSnapshot"
    test "should take fullPage screenshots"

    @tag skip: "not ported: toMatchSnapshot"
    test "should take fullPage screenshots and mask elements outside of it"

    test "should restore viewport after fullPage screenshot", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot = Page.screenshot!(page, full_page: true)
      assert is_binary(screenshot)
      verify_viewport(page, 500, 500)
    end

    @tag skip: "not ported: toMatchSnapshot"
    test "should allow transparency"

    @tag skip: "not ported: toMatchSnapshot"
    test "should render white background on jpeg file"

    @tag skip: "not ported: toMatchSnapshot"
    test "should produce a valid webp screenshot"

    @tag skip: "not ported: toMatchSnapshot"
    test "path option should detect webp"

    test "quality option should work for webp", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/grid.html")
      low_quality = Page.screenshot!(page, type: :webp, quality: 0)
      high_quality = Page.screenshot!(page, type: :webp, quality: 100)
      assert byte_size(low_quality) < byte_size(high_quality)
    end

    test "webp screenshots should be lossless by default", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/grid.html")
      assert lossless_webp?(Page.screenshot!(page, type: :webp)) == true
      assert lossless_webp?(Page.screenshot!(page, type: :webp, quality: 80)) == false
    end

    @tag skip: "not ported: decodeWebp"
    test "should allow transparency with webp"

    test "quality option should throw for webp when out of range", %{page: page} do
      {:error, error} = Page.screenshot(page, type: :webp, quality: 101)
      assert Exception.message(error) =~ "Expected options.quality to be between 0 and 100"
    end

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with odd clip size on Retina displays"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work for canvas"

    @tag skip: "not ported: toMatchSnapshot"
    test "should capture canvas changes"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work for webgl"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work for translateZ"

    test "should work while navigating", %{page: page, server: server} do
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

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with iframe in shadow"

    @tag skip: "not ported: toMatchSnapshot"
    test "path option should work"

    @tag skip: "not ported: toMatchSnapshot"
    test "path option should create subdirectories"

    @tag skip: "not ported: toMatchSnapshot"
    test "path option should detect jpeg"

    test "path option should throw for unsupported mime type", %{page: page} do
      {:error, error} = Page.screenshot(page, path: "file.txt")
      assert Exception.message(error) =~ ~s(path: unsupported mime type "text/plain")
    end

    test "quality option should throw for png", %{page: page} do
      {:error, error} = Page.screenshot(page, quality: 10)
      assert Exception.message(error) =~ "options.quality is unsupported for the png"
    end

    test "zero quality option should throw for png", %{page: page} do
      {:error, error} = Page.screenshot(page, quality: 0, type: :png)
      assert Exception.message(error) =~ "options.quality is unsupported for the png"
    end

    test "quality option should work for jpeg", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/grid.html")
      zero_quality = Page.screenshot!(page, type: :jpeg, quality: 0)
      high_quality = Page.screenshot!(page, type: :jpeg, quality: 100)
      assert byte_size(zero_quality) < byte_size(high_quality)
    end

    @tag :tmp_dir
    test "should prefer type over extension", %{page: page, tmp_dir: tmp_dir} do
      output_path = Path.join(tmp_dir, "file.png")
      buffer = Page.screenshot!(page, path: output_path, type: :jpeg)
      assert binary_part(buffer, 0, 3) == <<0xFF, 0xD8, 0xFF>>
    end

    test "should not issue resize event", %{page: page, server: server} do
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

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with Array deleted"

    test "should take fullPage screenshots during navigation", %{page: page, server: server} do
      # it.slow()
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      reload_several_times = Task.async(fn -> for _ <- 1..5, do: Page.reload!(page) end)
      screenshot_several_times = Task.async(fn -> for _ <- 1..5, do: Page.screenshot!(page, full_page: true) end)
      Task.await_many([reload_several_times, screenshot_several_times], 60_000)
    end
  end

  # Nested upstream: describe('page screenshot') > describe('mask option').
  describe "page screenshot mask option" do
    @tag skip: "not ported: toMatchSnapshot"
    test "should work"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with locator"

    @tag skip: "not ported: toMatchSnapshot"
    test "should work with elementhandle"

    @tag skip: "not ported: toMatchSnapshot"
    test "should mask multiple elements"

    @tag skip: "not ported: toMatchSnapshot"
    test "should mask inside iframe"

    @tag skip: "not ported: toMatchSnapshot"
    test "should mask in parallel"

    test "should remove mask after screenshot", %{page: page, server: server} do
      Page.set_viewport_size!(page, %{width: 500, height: 500})
      Page.goto!(page, server.prefix <> "/grid.html")
      screenshot1 = Page.screenshot!(page)
      Page.screenshot!(page, mask: [Locator.nth(Page.locator(page, "div"), 1)])
      screenshot2 = Page.screenshot!(page)
      assert screenshot1 == screenshot2
    end

    test "should work when subframe has stalled navigation", %{page: page, server: server} do
      test = self()
      # Stalling subframe.
      Page.route!(page, "**/subframe.html", fn route -> send(test, {:route, route}) end)

      Page.goto!(page, server.empty_page)
      done = Task.async(fn -> Page.set_content!(page, "<iframe src='/subframe.html'></iframe>") end)
      assert_receive {:route, route}, 5000

      Page.screenshot!(page, mask: [Page.locator(page, "non-existent")])
      Route.fulfill!(route, body: "")
      Task.await(done)
    end

    test "should work when subframe used document.open after a weird url", %{page: page, server: server} do
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

    @tag skip: "not ported: toMatchSnapshot"
    test "should work when mask color is not pink #F0F"

    @tag skip: "not ported: toMatchSnapshot"
    test "should hide elements based on attr"

    @tag skip: "not ported: toMatchSnapshot"
    test "should remove elements based on attr"
  end

  describe "page screenshot animations" do
    test "should not capture infinite css animation", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/rotate-z.html")
      div = Page.locator(page, "div")
      screenshot = Locator.screenshot!(div, animations: :disabled)

      for _ <- 0..9 do
        rafraf(page)
        new_screenshot = Locator.screenshot!(div, animations: :disabled)
        assert new_screenshot == screenshot
      end
    end

    test "should not capture pseudo element css animation", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/rotate-pseudo.html")
      div = Page.locator(page, "div")
      screenshot = Locator.screenshot!(div, animations: :disabled)

      for _ <- 0..9 do
        rafraf(page)
        new_screenshot = Locator.screenshot!(div, animations: :disabled)
        assert new_screenshot == screenshot
      end
    end

    test "should not capture css animations in shadow DOM", %{page: page, server: server} do
      # it.skip(isAndroid, 'Different viewport')
      Page.goto!(page, server.prefix <> "/rotate-z-shadow-dom.html")
      screenshot = Page.screenshot!(page, animations: :disabled)

      for _ <- 0..3 do
        rafraf(page)
        new_screenshot = Page.screenshot!(page, animations: :disabled)
        assert new_screenshot == screenshot
      end
    end

    @tag skip: "not ported: __testHookBeforeScreenshot, comparePNGs"
    test "should stop animations that happen right before screenshot"

    @tag skip: "not ported: comparePNGs"
    test "should resume infinite animations"

    @tag skip: "not ported: comparePNGs"
    test "should not capture infinite web animations"

    test "should fire transitionend for finite transitions", %{page: page, server: server} do
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

    test "should capture screenshots after layoutchanges in transitionend event", %{page: page, server: server} do
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

    test "should not change animation with playbackRate equal to 0", %{page: page, server: server} do
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

    test "should trigger particular events for css transitions", %{page: page, server: server} do
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

      console = Page.wait_for_event(page, :console, predicate: &(ConsoleMessage.text(&1) == "transitionend"))
      Page.screenshot!(page, animations: :disabled)
      PlaywrightEx.Promise.await!(console)
      assert Page.evaluate!(page, "() => window._EVENTS") == ["onfinish", "transitionend"]
    end

    test "should trigger particular events for INfinite css animation", %{page: page, server: server} do
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

      console = Page.wait_for_event(page, :console, predicate: &(ConsoleMessage.text(&1) == "animationcancel"))
      Page.screenshot!(page, animations: :disabled)
      PlaywrightEx.Promise.await!(console)
      assert Page.evaluate!(page, "() => window._EVENTS") == ["oncancel", "animationcancel"]
    end

    test "should trigger particular events for finite css animation", %{page: page, server: server} do
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

      console = Page.wait_for_event(page, :console, predicate: &(ConsoleMessage.text(&1) == "animationend"))
      Page.screenshot!(page, animations: :disabled)
      PlaywrightEx.Promise.await!(console)
      assert Page.evaluate!(page, "() => window._EVENTS") == ["onfinish", "animationend"]
    end

    @tag skip: "not ported: toMatchSnapshot"
    test "should wait for fonts to load"
  end

  test "should throw if screenshot size is too large", %{page: page, browser_name: browser_name} do
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
  test "page screenshot should capture css transform", %{page: page, browser_name: browser_name, tmp_dir: tmp_dir} do
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
  test "should capture css box-shadow", %{page: page, browser_name: browser_name, tmp_dir: tmp_dir} do
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
