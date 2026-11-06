defmodule PlaywrightEx.Examples.LocatorTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  example "Locator.all",
    js: ~S"""
    for (const li of await page.getByRole('listitem').all())
      await li.click();
    """,
    html: "<ul><li>one</li><li>two</li></ul>" do
    for li <- Page.get_by_role(page, :listitem) |> Locator.all!() do
      Locator.click!(li)
    end
  end

  example "Locator.boundingBox",
    js: ~S"""
    const box = await page.getByRole('button').boundingBox();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    """,
    html: "<button>Go</button>" do
    box = Page.get_by_role(page, :button) |> Locator.bounding_box!()
    Mouse.click!(Page.mouse(page), box.x + box.width / 2, box.y + box.height / 2)
  end

  example "Locator.click",
    js: ~S"""
    await page.locator('canvas').click({
      button: 'right',
      modifiers: ['Shift'],
      position: { x: 23, y: 32 },
    });
    """,
    html: "<canvas></canvas>" do
    Page.locator(page, "canvas")
    |> Locator.click!(button: :right, modifiers: [:shift], position: %{x: 23, y: 32})
  end

  example "Locator.evaluate",
    js: ~S"""
    const result = await page.getByTestId('myId').evaluate((element, [x, y]) => {
      return element.textContent + ' ' + x * y;
    }, [7, 8]);
    console.log(result); // prints "myId text 56"
    """,
    html: ~s(<div data-testid="myId">myId text</div>) do
    result =
      Page.get_by_test_id(page, "myId")
      |> Locator.evaluate!("(element, [x, y]) => element.textContent + ' ' + x * y", [7, 8])

    # prints "myId text 56"
    IO.puts(result)
  end
end
