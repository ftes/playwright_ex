defmodule PlaywrightEx.PromiseTest do
  # The public `PlaywrightEx.Promise`: `async/1` starts calls now, awaited later.
  use PlaywrightEx.Case, async: true

  alias PlaywrightEx.Promise
  alias PlaywrightEx.Test.TestInfo

  # Resolves on the next click: it must be in place before the click.
  @next_click "() => new Promise(r => document.querySelector('button').addEventListener('click', () => r('clicked')))"

  test "async/1 sends the call before the next action, awaited later", %{page: page} do
    Page.set_content!(page, "<button>Go</button>")

    for _ <- 1..20 do
      clicked = Promise.async(fn -> Page.evaluate!(page, @next_click) end)
      Page.get_by_role(page, :button) |> Locator.click!()
      assert Promise.await!(clicked) == "clicked"
    end
  end

  test "async/1: any process awaits it, any number of times; errors are its result", %{page: page} do
    Page.set_content!(page, "<button>Go</button>")
    clicked = Promise.async(fn -> Page.evaluate!(page, @next_click) end)
    Page.get_by_role(page, :button) |> Locator.click!()

    assert Task.await(Task.async(fn -> Promise.await!(clicked) end)) == "clicked"
    assert Promise.await(clicked) == {:ok, "clicked"}

    failed = Promise.async(fn -> Page.evaluate!(page, "() => { throw new Error('boom') }") end)
    assert {:error, %PlaywrightEx.PlaywrightError{message: message}} = Promise.await(failed)
    assert message =~ "boom"

    raised = Promise.async(fn -> raise ArgumentError, "not a Playwright error" end)
    assert_raise ArgumentError, "not a Playwright error", fn -> Promise.await(raised) end
    assert :ok = Promise.free(raised)
  end

  test "async/1 runs on the test's behalf: a soft matcher in it fails the test", %{page: page} do
    soft = Promise.async(fn -> Page.locator(page, "h1") |> Expect.soft() |> Expect.to_have_text!("x", timeout: 1) end)
    assert Promise.await!(soft) == :ok
    assert [{:error, %PlaywrightEx.ExpectError{}, _}] = TestInfo.take_errors(self())
  end
end
