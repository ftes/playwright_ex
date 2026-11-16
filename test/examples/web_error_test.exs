# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Examples.WebErrorTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use Playwright.ExampleCase, async: true

  alias Playwright.WebError

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
