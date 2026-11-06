defmodule PlaywrightEx.Examples.WebErrorTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.WebError

  example "WebError",
    js: ~S"""
    // Log all uncaught errors to the terminal
    context.on('weberror', webError => {
      console.log(`Uncaught exception: "${webError.error()}"`);
    });

    // Navigate to a page with an exception.
    await page.goto('data:text/html,<script>throw new Error("Test")</script>');
    """ do
    # Log all uncaught errors to the terminal
    BrowserContext.on(context, :web_error, fn web_error ->
      IO.puts(~s(Uncaught exception: "#{Exception.message(WebError.error(web_error))}"))
    end)

    # Navigate to a page with an exception.
    Page.goto!(page, ~s{data:text/html,<script>throw new Error("Test")</script>})
  end
end
