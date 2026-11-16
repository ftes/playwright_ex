# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Examples.DialogTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use Playwright.ExampleCase, async: true

  alias Playwright.Dialog
  alias Playwright.TestBrowser

  example "Dialog",
    js: ~S"""
    const { chromium } = require('playwright');  // Or 'firefox' or 'webkit'.

    (async () => {
      const browser = await chromium.launch();
      const page = await browser.newPage();
      page.on('dialog', async dialog => {
        console.log(dialog.message());
        await dialog.dismiss();
      });
      await page.evaluate(() => alert('1'));
      await browser.close();
    })();
    """,
    skip: TestBrowser.name() != "chromium" && "launches Chromium: runs with BROWSER=chromium" do
    # Or Playwright.firefox/1 or Playwright.webkit/1.
    browser = Playwright.chromium(playwright) |> BrowserType.launch!()
    page = Browser.new_page!(browser)

    Page.on(page, :dialog, fn dialog ->
      IO.puts(Dialog.message(dialog))
      Dialog.dismiss!(dialog)
    end)

    Page.evaluate!(page, "() => alert('1')")
    Browser.close!(browser)
  end
end
