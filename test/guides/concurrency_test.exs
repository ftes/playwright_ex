defmodule PlaywrightEx.Guides.ConcurrencyTest do
  # The snippets of `guides/concurrency.md` that run against a page.
  use PlaywrightEx.Case, async: true

  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Promise

  test "calls you await later: Promise.async before the action", %{page: page} do
    Page.set_content!(page, "<button>Go</button>")

    clicked = Promise.async(fn -> Page.evaluate!(page, "() => new Promise(r => onclick = () => r(true))") end)
    Locator.click!(Page.get_by_role(page, :button))
    true = Promise.await!(clicked)
  end

  test "calls you await later: a Task for a click that opens a dialog", %{page: page} do
    Page.set_content!(page, ~s{<button onclick="document.title = confirm('Sure?')">Delete</button>})

    dialog = Page.wait_for_event(page, :dialog)
    click = Task.async(fn -> Locator.click!(Page.get_by_role(page, :button)) end)
    Dialog.accept!(Promise.await!(dialog))
    Task.await(click)

    assert Page.title!(page) == "true"
  end
end
