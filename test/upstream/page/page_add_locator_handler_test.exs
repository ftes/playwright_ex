defmodule PlaywrightEx.Page.PageAddLocatorHandlerTest do
  @upstream "tests/page/page-add-locator-handler.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  # Handlers report to the test process: `++called` is `send(test, :called)`.
  defp called(count \\ 0, message \\ :called) do
    receive do
      ^message -> called(count + 1, message)
    after
      0 -> count
    end
  end

  test "should work", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    original_locator = Page.get_by_text(page, "This interstitial covers the button")

    Page.add_locator_handler!(page, original_locator, fn locator_argument ->
      # expect(locatorArgument).toBe(originalLocator): checked by the test process, per step.
      send(test, {:argument, locator_argument})
      send(test, :before)
      Locator.click!(Page.locator(page, "#close"))
      send(test, :after)
    end)

    for args <- [
          ["mouseover", 1],
          ["mouseover", 1, "capture"],
          ["mouseover", 2],
          ["mouseover", 2, "capture"],
          ["pointerover", 1],
          ["pointerover", 1, "capture"],
          ["none", 1],
          ["remove", 1],
          ["hide", 1]
        ] do
      # test.step(...)
      Locator.hover!(Page.locator(page, "#aside"))

      Page.evaluate!(
        page,
        """
        args => {
          window.clicked = 0;
          window.setupAnnoyingInterstitial(...args);
        }
        """,
        args
      )

      assert called(0, :before) == 0
      assert called(0, :after) == 0
      Locator.click!(Page.locator(page, "#target"))
      assert called(0, {:argument, original_locator}) == Enum.at(args, 1)
      assert called(0, :before) == Enum.at(args, 1)
      assert called(0, :after) == Enum.at(args, 1)
      assert Page.evaluate!(page, "window.clicked") == 1
      Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))
    end
  end

  test "should work with a custom check", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")

    Page.add_locator_handler!(
      page,
      Page.locator(page, "body"),
      fn ->
        if Locator.is_visible!(Page.get_by_text(page, "This interstitial covers the button")),
          do: Locator.click!(Page.locator(page, "#close"))
      end,
      no_wait_after: true
    )

    for args <- [["mouseover", 2], ["none", 1], ["remove", 1], ["hide", 1]] do
      # test.step(...)
      Locator.hover!(Page.locator(page, "#aside"))

      Page.evaluate!(
        page,
        """
        args => {
          window.clicked = 0;
          window.setupAnnoyingInterstitial(...args);
        }
        """,
        args
      )

      Locator.click!(Page.locator(page, "#target"))
      assert Page.evaluate!(page, "window.clicked") == 1
      Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))
    end
  end

  test "should work with locator.hover()", %{page: page, server: server} do
    # test.skip(!headless, 'Stray hovers in headed mode');
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")

    Page.add_locator_handler!(page, Page.get_by_text(page, "This interstitial covers the button"), fn ->
      Locator.click!(Page.locator(page, "#close"))
    end)

    Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.setupAnnoyingInterstitial('pointerover', 1, 'capture');
    }
    """)

    Locator.hover!(Page.locator(page, "#target"))
    Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))

    assert Page.eval_on_selector!(page, "#target", "e => window.getComputedStyle(e).backgroundColor") ==
             "rgb(255, 255, 0)"
  end

  test "should not work with force:true", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")

    Page.add_locator_handler!(page, Page.get_by_text(page, "This interstitial covers the button"), fn ->
      Locator.click!(Page.locator(page, "#close"))
    end)

    Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.setupAnnoyingInterstitial('none', 1);
    }
    """)

    Locator.click!(Page.locator(page, "#target"), force: true, timeout: 2000)
    assert Locator.is_visible!(Page.locator(page, "#interstitial")) == true
    assert Page.evaluate!(page, "window.clicked") == nil
  end

  test "should throw when handler times out", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    Page.add_locator_handler!(page, Page.get_by_text(page, "This interstitial covers the button"), fn ->
      send(test, :called)
      # Deliberately timeout: await a promise that does not settle while the page is open.
      PlaywrightEx.Promise.await(Page.wait_for_event(page, :close, timeout: 0))
    end)

    Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('mouseover', 1);
    }
    """)

    {:error, error} = Locator.click(Page.locator(page, "#target"), timeout: 3000)
    assert error.message =~ "Timeout 3000ms exceeded"

    {:error, error2} = Locator.click(Page.locator(page, "#target"), timeout: 3000)
    assert error2.message =~ "Timeout 3000ms exceeded"

    # Should not enter the same handler while it is still running.
    assert called() == 1
  end

  test "should work with toBeVisible", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    Page.add_locator_handler!(page, Page.get_by_text(page, "This interstitial covers the button"), fn ->
      send(test, :called)
      Locator.click!(Page.locator(page, "#close"))
    end)

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('remove', 1);
    }
    """)

    Expect.to_be_visible!(Page.locator(page, "#target"))
    Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))
    assert called() == 1
  end

  test "should work with locator.waitFor", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    Page.add_locator_handler!(page, Page.get_by_text(page, "This interstitial covers the button"), fn ->
      send(test, :called)
      Locator.click!(Page.locator(page, "#close"))
    end)

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('remove', 1);
    }
    """)

    Locator.wait_for!(Page.locator(page, "#target"))
    Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))
    assert called() == 1
  end

  @tag :tmp_dir
  test "should work with toHaveScreenshot", %{page: page, server: server, browser_name: browser_name, tmp_dir: tmp_dir} do
    # test.fixme(isAndroid, 'Screenshots are cut off on Android');
    Page.set_viewport_size!(page, %{width: 500, height: 500})
    Page.goto!(page, server.prefix <> "/grid.html")

    Page.evaluate!(page, """
    () => {
      const overlay = document.createElement('div');
      document.body.append(overlay);
      overlay.style.position = 'absolute';
      overlay.style.left = '0';
      overlay.style.right = '0';
      overlay.style.top = '0';
      overlay.style.bottom = '0';
      overlay.style.backgroundColor = 'red';

      const closeButton = document.createElement('button');
      overlay.appendChild(closeButton);
      closeButton.textContent = 'close';
      closeButton.addEventListener('click', () => overlay.remove());
    }
    """)

    Page.add_locator_handler!(page, Page.get_by_role(page, :button, name: "close"), fn ->
      Locator.click!(Page.get_by_role(page, :button, name: "close"))
    end)

    # The runner resolves 'screenshot-grid.png' to the spec's snapshot; failures write next to the copy.
    path = Path.join(tmp_dir, "screenshot-grid.png")

    File.cp!(
      Path.join(
        PlaywrightEx.Upstream.dir(),
        "tests/page/page-add-locator-handler.spec.ts-snapshots/screenshot-grid-#{browser_name}.png"
      ),
      path
    )

    Expect.to_have_screenshot!(page, path: path)
  end

  test "should work when owner frame detaches", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      const iframe = document.createElement('iframe');
      iframe.src = 'data:text/html,<body>hello from iframe</body>';
      document.body.append(iframe);

      const target = document.createElement('button');
      target.textContent = 'Click me';
      target.id = 'target';
      target.addEventListener('click', () => window._clicked = true);
      document.body.appendChild(target);

      const closeButton = document.createElement('button');
      closeButton.textContent = 'close';
      closeButton.id = 'close';
      closeButton.addEventListener('click', () => iframe.remove());
      document.body.appendChild(closeButton);
    }
    """)

    Page.add_locator_handler!(page, FrameLocator.locator(Page.frame_locator(page, "iframe"), "body"), fn ->
      Locator.click!(Page.locator(page, "#close"))
    end)

    Locator.click!(Page.locator(page, "#target"))
    assert Page.query_selector!(page, "iframe") == nil
    assert Page.evaluate!(page, "window._clicked") == true
  end

  test "should work with times: option", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    Page.add_locator_handler!(page, Page.locator(page, "body"), fn -> send(test, :called) end,
      no_wait_after: true,
      times: 2
    )

    Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('mouseover', 4);
    }
    """)

    {:error, error} = Locator.click(Page.locator(page, "#target"), timeout: 3000)
    assert called() == 2
    assert Page.evaluate!(page, "window.clicked") == 0
    Expect.to_be_visible!(Page.locator(page, "#interstitial"))
    assert error.message =~ "Timeout 3000ms exceeded"

    assert error.message =~
             ~s(<div>This interstitial covers the button</div> from <div class="visible" id="interstitial">…</div> subtree intercepts pointer events)
  end

  test "should wait for hidden by default", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    Page.add_locator_handler!(page, Page.get_by_role(page, :button, name: "close"), fn button ->
      send(test, :called)
      Locator.click!(button)
    end)

    Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('timeout', 1);
    }
    """)

    Locator.click!(Page.locator(page, "#target"))
    assert Page.evaluate!(page, "window.clicked") == 1
    Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))
    assert called() == 1
  end

  test "should wait for hidden by default 2", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    Page.add_locator_handler!(page, Page.get_by_role(page, :button, name: "close"), fn _button ->
      send(test, :called)
    end)

    Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('hide', 1);
    }
    """)

    {:error, error} = Locator.click(Page.locator(page, "#target"), timeout: 3000)
    assert Page.evaluate!(page, "window.clicked") == 0
    assert Locator.is_visible!(Page.locator(page, "#interstitial")) == true
    assert called() == 1

    assert error.message =~
             "locator handler has finished, waiting for getByRole('button', { name: 'close' }) to be hidden"
  end

  test "should work with noWaitAfter", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()
    {:ok, called} = Agent.start_link(fn -> 0 end)

    Page.add_locator_handler!(
      page,
      Page.get_by_role(page, :button, name: "close"),
      fn button ->
        send(test, :called)

        if Agent.get_and_update(called, &{&1 + 1, &1 + 1}) == 1,
          do: Locator.click!(button),
          else: Locator.wait_for!(Page.locator(page, "#interstitial"), state: :hidden)
      end,
      no_wait_after: true
    )

    Locator.hover!(Page.locator(page, "#aside"))

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('timeout', 1);
    }
    """)

    Locator.click!(Page.locator(page, "#target"))
    assert Page.evaluate!(page, "window.clicked") == 1
    Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))
    assert called() == 2
  end

  test "should removeLocatorHandler", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/handle-locator.html")
    test = self()

    Page.add_locator_handler!(page, Page.get_by_role(page, :button, name: "close"), fn locator ->
      send(test, :called)
      Locator.click!(locator)
    end)

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('hide', 1);
    }
    """)

    Locator.click!(Page.locator(page, "#target"))
    assert called() == 1
    assert Page.evaluate!(page, "window.clicked") == 1
    Expect.not_to_be_visible!(Page.locator(page, "#interstitial"))

    Page.evaluate!(page, """
    () => {
      window.clicked = 0;
      window.setupAnnoyingInterstitial('hide', 1);
    }
    """)

    Page.remove_locator_handler!(page, Page.get_by_role(page, :button, name: "close"))

    {:error, error} = Locator.click(Page.locator(page, "#target"), timeout: 3000)
    assert called() == 0
    assert Page.evaluate!(page, "window.clicked") == 0
    Expect.to_be_visible!(Page.locator(page, "#interstitial"))
    assert error.message =~ "Timeout 3000ms exceeded"
  end
end
