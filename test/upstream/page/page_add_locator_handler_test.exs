defmodule PlaywrightEx.Page.PageAddLocatorHandlerTest do
  @upstream "tests/page/page-add-locator-handler.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.FrameLocator
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  # Handlers report to the test process: `++called` is `send(test, :called)`.
  defp called(count \\ 0) do
    receive do
      :called -> called(count + 1)
    after
      0 -> count
    end
  end

  @tag skip: "not ported: expect"
  test "should work"

  @tag skip: "not ported: expect"
  test "should work with a custom check"

  @tag skip: "not ported: expect"
  test "should work with locator.hover()"

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

  @tag skip: "not ported: expect"
  test "should work with toBeVisible"

  @tag skip: "not ported: expect"
  test "should work with locator.waitFor"

  @tag skip: "not ported: expect"
  test "should work with toHaveScreenshot"

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

  @tag skip: "not ported: expect"
  test "should work with times: option"

  @tag skip: "not ported: expect"
  test "should wait for hidden by default"

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

  @tag skip: "not ported: expect"
  test "should work with noWaitAfter"

  @tag skip: "not ported: expect"
  test "should removeLocatorHandler"
end
