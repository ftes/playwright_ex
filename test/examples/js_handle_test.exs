defmodule PlaywrightEx.Examples.JSHandleTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.JSHandle

  example "JSHandle",
    js: ~S"""
    const windowHandle = await page.evaluateHandle(() => window);
    // ...
    """ do
    window_handle = Page.evaluate_handle!(page, "() => window")
    # ...
  end

  example "JSHandle.evaluate",
    js: ~S"""
    const tweetHandle = await page.$('.tweet .retweets');
    expect(await tweetHandle.evaluate(node => node.innerText)).toBe('10 retweets');
    """,
    html: ~s(<div class="tweet"><div class="retweets">10 retweets</div></div>) do
    tweet_handle = Page.query_selector!(page, ".tweet .retweets")
    assert JSHandle.evaluate!(tweet_handle, "node => node.innerText") == "10 retweets"
  end

  example "JSHandle.getProperties",
    js: ~S"""
    const handle = await page.evaluateHandle(() => ({ window, document }));
    const properties = await handle.getProperties();
    const windowHandle = properties.get('window');
    const documentHandle = properties.get('document');
    await handle.dispose();
    """ do
    handle = Page.evaluate_handle!(page, "() => ({ window, document })")
    properties = JSHandle.get_properties!(handle)
    window_handle = properties["window"]
    document_handle = properties["document"]
    JSHandle.dispose!(handle)
  end
end
