defmodule PlaywrightEx.Page.WheelTest do
  @upstream "tests/page/wheel.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  setup %{browser_name: browser_name} do
    # Chromium reports deltaX/deltaY scaled by host device scale factor.
    # https://bugs.chromium.org/p/chromium/issues/detail?id=1324819
    # https://github.com/microsoft/playwright/issues/7362
    # Different bots have different scale factors (usually 1 or 2), so we just ignore the values
    # instead of guessing the host scale factor.
    %{ignore_delta: browser_name == "chromium" and :os.type() == {:unix, :darwin}}
  end

  # await expect.poll(() => page.evaluate('window.lastEvent')).toBeTruthy()
  defp poll_last_event(page, tries \\ 50) do
    case Page.evaluate!(page, "window.lastEvent") do
      received when received in [nil, false] and tries > 0 ->
        Process.sleep(100)
        poll_last_event(page, tries - 1)

      received ->
        received
    end
  end

  defp expect_event(page, expected, ignore_delta) do
    received = poll_last_event(page)
    assert received

    {received, expected} =
      if ignore_delta,
        do: {Map.drop(received, ["deltaX", "deltaY"]), Map.drop(expected, ["deltaX", "deltaY"])},
        else: {received, expected}

    assert received == expected
  end

  test "should dispatch wheel events @smoke", %{page: page, ignore_delta: ignore_delta} do
    Page.set_content!(page, ~s(<div style="width: 5000px; height: 5000px;"></div>))
    Mouse.move!(Page.mouse(page), 50, 60)
    listen_for_wheel_events(page, "div")
    Mouse.wheel!(Page.mouse(page), 0, 100)
    Page.wait_for_function!(page, "window.scrollY === 100")

    expect_event(
      page,
      %{
        "deltaX" => 0,
        "deltaY" => 100,
        "clientX" => 50,
        "clientY" => 60,
        "deltaMode" => 0,
        "ctrlKey" => false,
        "shiftKey" => false,
        "altKey" => false,
        "metaKey" => false
      },
      ignore_delta
    )
  end

  test "should dispatch wheel events after popup was opened @smoke", %{page: page, ignore_delta: ignore_delta} do
    Page.set_content!(page, """
      <div style="width: 5000px; height: 5000px;"></div>
    """)

    Mouse.move!(Page.mouse(page), 50, 60)
    listen_for_wheel_events(page, "div")
    Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => window.open('')") end)
    Mouse.wheel!(Page.mouse(page), 0, 100)
    Page.wait_for_function!(page, "window.scrollY === 100")

    expect_event(
      page,
      %{
        "deltaX" => 0,
        "deltaY" => 100,
        "clientX" => 50,
        "clientY" => 60,
        "deltaMode" => 0,
        "ctrlKey" => false,
        "shiftKey" => false,
        "altKey" => false,
        "metaKey" => false
      },
      ignore_delta
    )
  end

  test "should dispatch wheel event on svg element", %{page: page, ignore_delta: ignore_delta} do
    Page.set_content!(page, """
      <body>
        <svg class="scroll-box"></svg>
      </body>
      <style>
        .scroll-box {
          position: absolute;
          top: 0px;
          left: 0px;
          background-color: brown;
          width: 200px;
          height: 200px;
        }
      </style>
    """)

    listen_for_wheel_events(page, "svg")
    Mouse.move!(Page.mouse(page), 100, 100)
    Mouse.wheel!(Page.mouse(page), 0, 100)
    Page.wait_for_function!(page, "!!window.lastEvent")

    expect_event(
      page,
      %{
        "deltaX" => 0,
        "deltaY" => 100,
        "clientX" => 100,
        "clientY" => 100,
        "deltaMode" => 0,
        "ctrlKey" => false,
        "shiftKey" => false,
        "altKey" => false,
        "metaKey" => false
      },
      ignore_delta
    )
  end

  test "should scroll when nobody is listening", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/scrollable.html")
    Mouse.move!(Page.mouse(page), 50, 60)
    Mouse.wheel!(Page.mouse(page), 0, 100)
    Page.wait_for_function!(page, "window.scrollY === 100")
  end

  test "should set the modifiers", %{page: page, ignore_delta: ignore_delta} do
    Page.set_content!(page, ~s(<div style="width: 5000px; height: 5000px;"></div>))
    Mouse.move!(Page.mouse(page), 50, 60)
    listen_for_wheel_events(page, "div")
    Keyboard.down!(Page.keyboard(page), "Shift")
    Mouse.wheel!(Page.mouse(page), 0, 100)

    expect_event(
      page,
      %{
        "deltaX" => 0,
        "deltaY" => 100,
        "clientX" => 50,
        "clientY" => 60,
        "deltaMode" => 0,
        "ctrlKey" => false,
        "shiftKey" => true,
        "altKey" => false,
        "metaKey" => false
      },
      ignore_delta
    )
  end

  test "should scroll horizontally", %{page: page, ignore_delta: ignore_delta} do
    Page.set_content!(page, ~s(<div style="width: 5000px; height: 5000px;"></div>))
    Mouse.move!(Page.mouse(page), 50, 60)
    listen_for_wheel_events(page, "div")
    Mouse.wheel!(Page.mouse(page), 100, 0)

    expect_event(
      page,
      %{
        "deltaX" => 100,
        "deltaY" => 0,
        "clientX" => 50,
        "clientY" => 60,
        "deltaMode" => 0,
        "ctrlKey" => false,
        "shiftKey" => false,
        "altKey" => false,
        "metaKey" => false
      },
      ignore_delta
    )

    Page.wait_for_function!(page, "window.scrollX === 100")
  end

  test "should work when the event is canceled", %{page: page, ignore_delta: ignore_delta} do
    Page.set_content!(page, ~s(<div style="width: 5000px; height: 5000px;"></div>))
    Mouse.move!(Page.mouse(page), 50, 60)
    listen_for_wheel_events(page, "div")

    Page.evaluate!(page, """
    () => {
      document.querySelector('div').addEventListener('wheel', e => e.preventDefault());
    }
    """)

    # Give wheel listener a chance to propagate through all the layers in Firefox.
    Utils.rafraf(page, 10)
    Mouse.wheel!(Page.mouse(page), 0, 100)

    expect_event(
      page,
      %{
        "deltaX" => 0,
        "deltaY" => 100,
        "clientX" => 50,
        "clientY" => 60,
        "deltaMode" => 0,
        "ctrlKey" => false,
        "shiftKey" => false,
        "altKey" => false,
        "metaKey" => false
      },
      ignore_delta
    )

    # Give the page a chance to scroll.
    Page.wait_for_function!(page, "!!window['lastEvent']")
    # Ensure that it did not.
    assert Page.evaluate!(page, "window.scrollY") == 0
  end

  defp listen_for_wheel_events(page, selector) do
    Page.evaluate!(
      page,
      """
      selector => {
        document.querySelector(selector).addEventListener('wheel', event => {
          const e = event;
          window['lastEvent'] = {
            deltaX: e.deltaX,
            deltaY: e.deltaY,
            clientX: e.clientX,
            clientY: e.clientY,
            deltaMode: e.deltaMode,
            ctrlKey: e.ctrlKey,
            shiftKey: e.shiftKey,
            altKey: e.altKey,
            metaKey: e.metaKey,
          };
        }, { passive: false });
      }
      """,
      selector
    )
  end
end
