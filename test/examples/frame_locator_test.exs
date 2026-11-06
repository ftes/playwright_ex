defmodule PlaywrightEx.Examples.FrameLocatorTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  example "FrameLocator",
    js: ~S"""
    const locator = page.locator('#my-frame').contentFrame().getByText('Submit');
    await locator.click();
    """,
    html: ~s(<iframe id="my-frame" srcdoc="<button>Submit</button>"></iframe>) do
    locator = Page.locator(page, "#my-frame") |> Locator.content_frame() |> FrameLocator.get_by_text("Submit")
    Locator.click!(locator)
  end

  example "FrameLocator",
    js: ~S"""
    // Throws if there are several frames in DOM:
    await page.locator('.result-frame').contentFrame().getByRole('button').click();

    // Works because we explicitly tell locator to pick the first frame:
    await page.locator('.result-frame').contentFrame().first().getByRole('button').click();
    """,
    html: ~s(<iframe class="result-frame" srcdoc="<button>Go</button>"></iframe>) do
    # Throws if there are several frames in DOM:
    Page.locator(page, ".result-frame")
    |> Locator.content_frame()
    |> FrameLocator.get_by_role(:button)
    |> Locator.click!()

    # Works because we explicitly tell locator to pick the first frame:
    Page.locator(page, ".result-frame")
    |> Locator.content_frame()
    |> FrameLocator.first()
    |> FrameLocator.get_by_role(:button)
    |> Locator.click!()
  end

  example "FrameLocator",
    js: ~S"""
    // Finds the button in any frame on the page:
    await page.frameLocator().getByRole('button').click();

    // Finds the iframe with id "my-frame" anywhere on the page, and clicks the button inside it:
    await page.frameLocator().locator('#my-frame').contentFrame().getByRole('button').click();
    """,
    html: ~s(<iframe id="my-frame" srcdoc="<button>Go</button>"></iframe>) do
    # Finds the button in any frame on the page:
    Page.frame_locator(page) |> FrameLocator.get_by_role(:button) |> Locator.click!()

    # Finds the iframe with id "my-frame" anywhere on the page, and clicks the button inside it:
    Page.frame_locator(page)
    |> FrameLocator.locator("#my-frame")
    |> Locator.content_frame()
    |> FrameLocator.get_by_role(:button)
    |> Locator.click!()
  end

  example "FrameLocator.owner",
    js: ~S"""
    const frameLocator = page.locator('iframe[name="embedded"]').contentFrame();
    // ...
    const locator = frameLocator.owner();
    await expect(locator).toBeVisible();
    """,
    html: ~s(<iframe name="embedded" srcdoc="<button>Go</button>"></iframe>) do
    frame_locator = Page.locator(page, ~s(iframe[name="embedded"])) |> Locator.content_frame()
    # ...
    locator = FrameLocator.owner(frame_locator)
    Expect.to_be_visible!(locator)
  end
end
