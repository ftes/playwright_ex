defmodule LiveViewE2E.ComponentsTest do
  use LiveViewE2E.Case

  # beforeEach: the listeners. upstream's module-level arrays, reset per test, are an Agent here,
  # which the afterEach (an on_exit, after the test) reads.
  setup %{page: page} do
    {:ok, errors} = Agent.start(fn -> %{console_errors: [], js_errors: []} end)

    # Listen for console errors
    Page.on(page, :console, fn msg ->
      if ConsoleMessage.type(msg) == "error" do
        Agent.update(
          errors,
          &Map.update!(&1, :console_errors, fn e -> e ++ [ConsoleMessage.text(msg)] end)
        )
      end
    end)

    # Listen for JavaScript errors
    Page.on(page, :page_error, fn error ->
      Agent.update(
        errors,
        &Map.update!(&1, :js_errors, fn e -> e ++ [Exception.message(error)] end)
      )
    end)

    # afterEach
    on_exit(fn ->
      # Not stopped: the listeners fire until the context closes, after this on_exit.
      %{console_errors: console_errors, js_errors: js_errors} = Agent.get(errors, & &1)
      # Assert no JavaScript errors occurred during the test
      assert js_errors == []
      assert console_errors == []
    end)
  end

  test "dropdown menu focus wrapping works correctly", %{page: page, browser_name: browser_name} do
    # skip if webkit, since it doesn't have tab focus enabled by default
    # (test.skip(): ExUnit has no runtime skip, the test passes without running)
    if browser_name != :webkit do
      Page.goto!(page, "/components?tab=focus_wrap")
      sync_lv(page)

      page |> Page.locator("#dropdown-menu") |> Expect.to_be_hidden!()
      page |> Page.locator("#dropdown-button") |> Locator.click!()
      page |> Page.locator("#dropdown-menu") |> Expect.to_be_visible!()

      dropdown_buttons = Page.locator(page, "#dropdown-content button")
      dropdown_buttons |> Locator.first() |> Expect.to_be_focused!()

      # Tab through dropdown items - focus should cycle within the dropdown
      page |> Page.keyboard() |> Keyboard.press!("Tab")
      dropdown_buttons |> Locator.nth(1) |> Expect.to_be_focused!()

      page |> Page.keyboard() |> Keyboard.press!("Tab")
      dropdown_buttons |> Locator.nth(2) |> Expect.to_be_focused!()

      # Tab again should cycle back to first item (focus wrap behavior)
      page |> Page.keyboard() |> Keyboard.press!("Tab")
      dropdown_buttons |> Locator.first() |> Expect.to_be_focused!()

      # Shift+Tab should go backwards
      page |> Page.keyboard() |> Keyboard.press!("Shift+Tab")
      dropdown_buttons |> Locator.nth(2) |> Expect.to_be_focused!()

      # Click a menu item to close dropdown
      dropdown_buttons |> Locator.first() |> Locator.click!()

      # Dropdown should be hidden again
      page |> Page.locator("#dropdown-menu") |> Expect.to_be_hidden!()
    end
  end

  test "simple focus container traps focus correctly", %{page: page, browser_name: browser_name} do
    # skip if webkit, since it doesn't have tab focus enabled by default
    if browser_name != :webkit do
      Page.goto!(page, "/components?tab=focus_wrap")
      sync_lv(page)

      # Click on first button in the focus container to start focus there
      container_buttons = Page.locator(page, "#simple-focus-container button")
      container_input = Page.locator(page, "#simple-focus-container input")

      container_buttons |> Locator.first() |> Locator.click!()
      container_buttons |> Locator.first() |> Expect.to_be_focused!()

      # Tab should move to second button
      page |> Page.keyboard() |> Keyboard.press!("Tab")
      container_buttons |> Locator.nth(1) |> Expect.to_be_focused!()

      # Tab should move to input
      page |> Page.keyboard() |> Keyboard.press!("Tab")
      Expect.to_be_focused!(container_input)

      # Tab should cycle back to first button (focus wrap behavior)
      page |> Page.keyboard() |> Keyboard.press!("Tab")
      container_buttons |> Locator.first() |> Expect.to_be_focused!()

      # Shift+Tab should go backwards to input
      page |> Page.keyboard() |> Keyboard.press!("Shift+Tab")
      Expect.to_be_focused!(container_input)

      # Shift+Tab should go to second button
      page |> Page.keyboard() |> Keyboard.press!("Shift+Tab")
      container_buttons |> Locator.nth(1) |> Expect.to_be_focused!()

      # Shift+Tab should go to first button
      page |> Page.keyboard() |> Keyboard.press!("Shift+Tab")
      container_buttons |> Locator.first() |> Expect.to_be_focused!()
    end
  end

  test "focus_wrap components have correct attributes", %{page: page} do
    Page.goto!(page, "/components?tab=focus_wrap")
    sync_lv(page)

    # Check that focus_wrap components have the correct phx-hook attribute
    # Check that focus sentinel spans are present
    page
    |> Page.locator("#dropdown-content")
    |> Expect.to_have_attribute!("phx-hook", "Phoenix.FocusWrap")

    page
    |> Page.locator("#simple-focus-container")
    |> Expect.to_have_attribute!("phx-hook", "Phoenix.FocusWrap")

    page |> Page.locator("#dropdown-content-start") |> Expect.to_have_attribute!("tabindex", "0")

    page
    |> Page.locator("#dropdown-content-start")
    |> Expect.to_have_attribute!("aria-hidden", "true")

    page |> Page.locator("#dropdown-content-end") |> Expect.to_have_attribute!("tabindex", "0")

    page
    |> Page.locator("#dropdown-content-end")
    |> Expect.to_have_attribute!("aria-hidden", "true")

    page
    |> Page.locator("#simple-focus-container-start")
    |> Expect.to_have_attribute!("tabindex", "0")

    page
    |> Page.locator("#simple-focus-container-start")
    |> Expect.to_have_attribute!("aria-hidden", "true")

    page
    |> Page.locator("#simple-focus-container-end")
    |> Expect.to_have_attribute!("tabindex", "0")

    page
    |> Page.locator("#simple-focus-container-end")
    |> Expect.to_have_attribute!("aria-hidden", "true")
  end
end
