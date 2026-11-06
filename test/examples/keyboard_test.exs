defmodule PlaywrightEx.Examples.KeyboardTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  example "Keyboard",
    js: ~S"""
    await page.keyboard.type('Hello World!');
    await page.keyboard.press('ArrowLeft');

    await page.keyboard.down('Shift');
    for (let i = 0; i < ' World'.length; i++)
      await page.keyboard.press('ArrowLeft');
    await page.keyboard.up('Shift');

    await page.keyboard.press('Backspace');
    // Result text will end up saying 'Hello!'
    """,
    html: "<input>",
    given: [_focus: Page.locator(page, "input") |> Locator.focus!()] do
    keyboard = Page.keyboard(page)
    Keyboard.type!(keyboard, "Hello World!")
    Keyboard.press!(keyboard, "ArrowLeft")

    Keyboard.down!(keyboard, "Shift")
    for _ <- 1..String.length(" World"), do: Keyboard.press!(keyboard, "ArrowLeft")
    Keyboard.up!(keyboard, "Shift")

    Keyboard.press!(keyboard, "Backspace")
    # Result text will end up saying 'Hello!'
  end

  example "Keyboard",
    js: ~S"""
    await page.keyboard.press('Shift+KeyA');
    // or
    await page.keyboard.press('Shift+A');
    """,
    html: "<input>",
    given: [_focus: Page.locator(page, "input") |> Locator.focus!()] do
    Page.keyboard(page) |> Keyboard.press!("Shift+KeyA")
    # or
    Page.keyboard(page) |> Keyboard.press!("Shift+A")
  end

  example "Keyboard",
    js: ~S"""
    await page.keyboard.press('ControlOrMeta+A');
    """,
    html: ~s(<input value="text">),
    given: [_focus: Page.locator(page, "input") |> Locator.focus!()] do
    Page.keyboard(page) |> Keyboard.press!("ControlOrMeta+A")
  end

  example "Keyboard.insertText",
    js: ~S"""
    await page.keyboard.insertText('嗨');
    """,
    html: "<input>",
    given: [_focus: Page.locator(page, "input") |> Locator.focus!()] do
    Page.keyboard(page) |> Keyboard.insert_text!("嗨")
  end

  example "Keyboard.press",
    js: ~S"""
    const page = await browser.newPage();
    await page.goto('https://keycode.info');
    await page.keyboard.press('A');
    await page.screenshot({ path: 'A.png' });
    await page.keyboard.press('ArrowLeft');
    await page.screenshot({ path: 'ArrowLeft.png' });
    await page.keyboard.press('Shift+O');
    await page.screenshot({ path: 'O.png' });
    await browser.close();
    """,
    skip: "navigates a browser of its own: not offline" do
    page = Browser.new_page!(browser)
    Page.goto!(page, "https://keycode.info")
    Page.keyboard(page) |> Keyboard.press!("A")
    Page.screenshot!(page, path: "A.png")
    Page.keyboard(page) |> Keyboard.press!("ArrowLeft")
    Page.screenshot!(page, path: "ArrowLeft.png")
    Page.keyboard(page) |> Keyboard.press!("Shift+O")
    Page.screenshot!(page, path: "O.png")
    Browser.close!(browser)
  end

  example "Keyboard.type",
    js: ~S"""
    await page.keyboard.type('Hello'); // Types instantly
    await page.keyboard.type('World', { delay: 100 }); // Types slower, like a user
    """,
    html: "<input>",
    given: [_focus: Page.locator(page, "input") |> Locator.focus!()] do
    # Types instantly
    Page.keyboard(page) |> Keyboard.type!("Hello")
    # Types slower, like a user
    Page.keyboard(page) |> Keyboard.type!("World", delay: 100)
  end
end
