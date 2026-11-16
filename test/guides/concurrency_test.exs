defmodule PlaywrightEx.Guides.ConcurrencyTest do
  # The snippets of `guides/concurrency.md` that run against a page.
  use PlaywrightEx.Case, async: true

  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Route

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

  test "a route handler that waits for the test hands off to a process", %{page: page} do
    Page.route(
      page,
      "**/empty.html",
      &Route.fulfill!(&1,
        body:
          "<p>Loading</p><script>fetch('/api/data').then(r => r.text()).then(t => document.querySelector('p').textContent = t)</script>",
        content_type: "text/html"
      )
    )

    test_pid = self()

    Page.route(page, "**/api/data", fn route ->
      # JS: `await released; await route.continue()`. Deviation: fulfilled, with no server.
      spawn(fn ->
        send(test_pid, {:held, self()})

        receive do
          :release -> Route.fulfill!(route, body: "Done")
        end
      end)
    end)

    Page.goto!(page, "https://example.com/empty.html")
    assert_receive {:held, held}, 5_000
    Expect.to_be_visible!(Page.get_by_text(page, "Loading"))
    send(held, :release)
    Expect.to_have_text!(Page.locator(page, "p"), "Done")
  end
end
