defmodule PlaywrightEx.Examples.WebStorageTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.WebStorage

  example "WebStorage",
    js: ~S"""
    await page.goto('https://example.com');
    await page.localStorage.setItem('token', 'abc');
    const token = await page.localStorage.getItem('token');
    const all = await page.localStorage.items();
    await page.localStorage.removeItem('token');
    await page.localStorage.clear();
    """ do
    Page.goto!(page, "https://example.com")
    Page.local_storage(page) |> WebStorage.set_item!("token", "abc")
    token = Page.local_storage(page) |> WebStorage.get_item!("token")
    all = Page.local_storage(page) |> WebStorage.items!()
    Page.local_storage(page) |> WebStorage.remove_item!("token")
    Page.local_storage(page) |> WebStorage.clear!()
  end
end
