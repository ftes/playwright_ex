defmodule PlaywrightEx.Examples.ConsoleMessageTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Promise

  example "ConsoleMessage",
    js: ~S"""
    // Listen for all console logs
    page.on('console', msg => console.log(msg.text()));

    // Listen for all console events and handle errors
    page.on('console', msg => {
      if (msg.type() === 'error')
        console.log(`Error text: "${msg.text()}"`);
    });

    // Get the next console log
    const msgPromise = page.waitForEvent('console');
    await page.evaluate(() => {
      console.log('hello', 42, { foo: 'bar' });  // Issue console.log inside the page
    });
    const msg = await msgPromise;

    // Deconstruct console log arguments
    await msg.args()[0].jsonValue(); // hello
    await msg.args()[1].jsonValue(); // 42
    """ do
    # Listen for all console logs
    Page.on(page, :console, &IO.puts(ConsoleMessage.text(&1)))

    # Listen for all console events and handle errors
    Page.on(page, :console, fn msg ->
      if ConsoleMessage.type(msg) == "error", do: IO.puts(~s(Error text: "#{ConsoleMessage.text(msg)}"))
    end)

    # Get the next console log
    msg_promise = Page.wait_for_event(page, :console)
    # Issue console.log inside the page
    Page.evaluate!(page, "() => console.log('hello', 42, { foo: 'bar' })")
    msg = Promise.await!(msg_promise)

    # Deconstruct console log arguments
    ConsoleMessage.args(msg) |> Enum.at(0) |> JSHandle.json_value!()
    # => "hello"
    ConsoleMessage.args(msg) |> Enum.at(1) |> JSHandle.json_value!()
    # => 42
  end
end
