defmodule PlaywrightEx.Examples.MouseTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  example "Mouse",
    js: ~S"""
    // Using ‘page.mouse’ to trace a 100x100 square.
    await page.mouse.move(0, 0);
    await page.mouse.down();
    await page.mouse.move(0, 100);
    await page.mouse.move(100, 100);
    await page.mouse.move(100, 0);
    await page.mouse.move(0, 0);
    await page.mouse.up();
    """ do
    # Using Page.mouse/1 to trace a 100x100 square.
    mouse = Page.mouse(page)
    Mouse.move!(mouse, 0, 0)
    Mouse.down!(mouse)
    Mouse.move!(mouse, 0, 100)
    Mouse.move!(mouse, 100, 100)
    Mouse.move!(mouse, 100, 0)
    Mouse.move!(mouse, 0, 0)
    Mouse.up!(mouse)
  end
end
