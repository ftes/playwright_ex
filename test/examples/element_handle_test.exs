defmodule PlaywrightEx.Examples.ElementHandleTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.ElementHandle

  example "ElementHandle",
    js: ~S"""
    const hrefElement = await page.$('a');
    await hrefElement.click();
    """,
    html: ~s(<a href="#target">link</a>) do
    href_element = Page.query_selector!(page, "a")
    ElementHandle.click!(href_element)
  end

  example "ElementHandle",
    js: ~S"""
    const handle = await page.$('text=Submit');
    // ...
    await handle.hover();
    await handle.click();
    """,
    html: "<button>Submit</button>" do
    handle = Page.query_selector!(page, "text=Submit")
    # ...
    ElementHandle.hover!(handle)
    ElementHandle.click!(handle)
  end

  example "ElementHandle",
    js: ~S"""
    const locator = page.getByText('Submit');
    // ...
    await locator.hover();
    await locator.click();
    """,
    html: "<button>Submit</button>" do
    locator = Page.get_by_text(page, "Submit")
    # ...
    Locator.hover!(locator)
    Locator.click!(locator)
  end

  example "ElementHandle.boundingBox",
    js: ~S"""
    const box = await elementHandle.boundingBox();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    """,
    html: "<button>Go</button>",
    given: [element_handle: Page.query_selector!(page, "button")] do
    box = ElementHandle.bounding_box!(element_handle)
    Mouse.click!(Page.mouse(page), box.x + box.width / 2, box.y + box.height / 2)
  end

  example "ElementHandle.dispatchEvent",
    js: ~S"""
    await elementHandle.dispatchEvent('click');
    """,
    html: "<button>Go</button>",
    given: [element_handle: Page.query_selector!(page, "button")] do
    ElementHandle.dispatch_event!(element_handle, "click")
  end

  example "ElementHandle.dispatchEvent",
    js: ~S"""
    // Note you can only create DataTransfer in Chromium and Firefox
    const dataTransfer = await page.evaluateHandle(() => new DataTransfer());
    await elementHandle.dispatchEvent('dragstart', { dataTransfer });
    """,
    html: ~s(<div draggable="true">Drag me</div>),
    given: [element_handle: Page.query_selector!(page, "div")] do
    # Note you can only create DataTransfer in Chromium and Firefox
    data_transfer = Page.evaluate_handle!(page, "() => new DataTransfer()")
    ElementHandle.dispatch_event!(element_handle, "dragstart", %{dataTransfer: data_transfer})
  end

  example "ElementHandle.evalOnSelector",
    js: ~S"""
    const tweetHandle = await page.$('.tweet');
    expect(await tweetHandle.$eval('.like', node => node.innerText)).toBe('100');
    expect(await tweetHandle.$eval('.retweets', node => node.innerText)).toBe('10');
    """,
    html: ~s(<div class="tweet"><div class="like">100</div><div class="retweets">10</div></div>) do
    tweet_handle = Page.query_selector!(page, ".tweet")
    assert ElementHandle.eval_on_selector!(tweet_handle, ".like", "node => node.innerText") == "100"
    assert ElementHandle.eval_on_selector!(tweet_handle, ".retweets", "node => node.innerText") == "10"
  end

  example "ElementHandle.evalOnSelectorAll",
    js: ~S"""
    const feedHandle = await page.$('.feed');
    expect(await feedHandle.$$eval('.tweet', nodes =>
      nodes.map(n => n.innerText))).toEqual(['Hello!', 'Hi!'],
    );
    """,
    html: ~s(<div class="feed"><div class="tweet">Hello!</div><div class="tweet">Hi!</div></div>) do
    feed_handle = Page.query_selector!(page, ".feed")

    assert ElementHandle.eval_on_selector_all!(feed_handle, ".tweet", "nodes => nodes.map(n => n.innerText)") ==
             ["Hello!", "Hi!"]
  end

  example "ElementHandle.selectOption",
    js: ~S"""
    // Single selection matching the value or label
    handle.selectOption('blue');

    // single selection matching the label
    handle.selectOption({ label: 'Blue' });

    // multiple selection
    handle.selectOption(['red', 'green', 'blue']);
    """,
    html: """
    <select multiple>
      <option value="red">Red</option>
      <option value="green">Green</option>
      <option value="blue">Blue</option>
    </select>
    """,
    given: [handle: Page.query_selector!(page, "select")] do
    # Single selection matching the value or label
    ElementHandle.select_option!(handle, "blue")

    # single selection matching the label
    ElementHandle.select_option!(handle, %{label: "Blue"})

    # multiple selection
    ElementHandle.select_option!(handle, ["red", "green", "blue"])
  end

  example "ElementHandle.waitForSelector",
    js: ~S"""
    await page.setContent(`<div><span></span></div>`);
    const div = await page.$('div');
    // Waiting for the 'span' selector relative to the div.
    const span = await div.waitForSelector('span', { state: 'attached' });
    """ do
    Page.set_content!(page, "<div><span></span></div>")
    div = Page.query_selector!(page, "div")
    # Waiting for the 'span' selector relative to the div.
    span = ElementHandle.wait_for_selector!(div, "span", state: :attached)
  end
end
