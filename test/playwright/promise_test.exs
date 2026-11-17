defmodule Playwright.PromiseTest do
  # The public `Playwright.Promise`: `async/1` starts calls now, awaited later.
  use Playwright.Case, async: true

  alias Playwright.ConsoleMessage
  alias Playwright.Promise
  alias Playwright.Test.TestInfo

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
    assert {:error, %Playwright.PlaywrightError{message: message}} = Promise.await(failed)
    assert message =~ "boom"

    raised = Promise.async(fn -> raise ArgumentError, "not a Playwright error" end)
    assert_raise ArgumentError, "not a Playwright error", fn -> Promise.await(raised) end
    assert :ok = Promise.free(raised)
  end

  test "async/1 runs on the test's behalf: a soft matcher in it fails the test", %{page: page} do
    soft = Promise.async(fn -> Page.locator(page, "h1") |> Expect.soft() |> Expect.to_have_text!("x", timeout: 1) end)
    assert Promise.await!(soft) == :ok
    assert [{:error, %Playwright.ExpectError{}, _}] = TestInfo.take_errors(self())
  end

  defp later(page, value, ms \\ 200),
    do: Promise.async(fn -> Page.evaluate!(page, "v => new Promise(r => setTimeout(() => r(v), #{ms}))", value) end)

  defp fail(page, message, ms \\ 0) do
    Promise.async(fn ->
      Page.evaluate!(page, "m => new Promise((_, j) => setTimeout(() => j(new Error(m)), #{ms}))", message)
    end)
  end

  defp never(page), do: Page.wait_for_event(page, :popup)

  describe "all/1, race/1, any/1" do
    test "all/1: values in input order, the same for every awaiter; [] is []", %{page: page} do
      all = Promise.all([later(page, "slow"), later(page, "fast", 0)])
      assert Promise.await!(all) == ["slow", "fast"]
      assert Task.await(Task.async(fn -> Promise.await!(all) end)) == ["slow", "fast"]
      assert Promise.await!(Promise.all([])) == []
    end

    test "all/1 rejects with the first rejection, without waiting for the rest", %{page: page} do
      all = Promise.all([never(page), fail(page, "late", 200), fail(page, "early")])
      assert {:error, %Playwright.PlaywrightError{message: message}} = Promise.await(all)
      assert message =~ "early"
    end

    test "race/1 settles as the first to settle, fulfilled or rejected; the losers run on", %{page: page} do
      slow = later(page, "slow")
      assert Promise.await!(Promise.race([slow, later(page, "fast", 0)])) == "fast"
      assert Promise.await!(slow) == "slow"

      slow = later(page, "slow")
      assert {:error, %{message: message}} = Promise.await(Promise.race([slow, fail(page, "boom")]))
      assert message =~ "boom"
      assert Promise.await!(slow) == "slow"
    end

    test "race/1: an event raced against a timer", %{page: page} do
      timer =
        Promise.async(fn ->
          Page.wait_for_timeout!(page, 100)
          :timeout
        end)

      assert Promise.await!(Promise.race([Page.wait_for_event(page, :dialog), timer])) == :timeout

      timer =
        Promise.async(fn ->
          Page.wait_for_timeout!(page, 10_000)
          :timeout
        end)

      race = Promise.race([Page.wait_for_event(page, :console), timer])
      Page.evaluate!(page, "() => console.log('hi')")
      assert ConsoleMessage.text(Promise.await!(race)) == "hi"
    end

    test "race([]) never settles" do
      race = Promise.race([])
      task = Task.async(fn -> Promise.await(race) end)
      assert Task.yield(task, 100) == nil
      Task.shutdown(task)
      assert Promise.free(race) == :ok
    end

    test "any/1: the first value, or an AggregateError of all rejections in input order", %{page: page} do
      assert Promise.await!(Promise.any([fail(page, "early"), never(page), later(page, "ok")])) == "ok"

      assert {:error, %Playwright.AggregateError{message: "All promises were rejected", errors: [late, early]}} =
               Promise.await(Promise.any([fail(page, "late", 200), fail(page, "early")]))

      assert late.message =~ "late"
      assert early.message =~ "early"

      assert {:error, %Playwright.AggregateError{errors: []}} = Promise.await(Promise.any([]))
    end

    test "any/1: an AggregateError of other errors (bugs) raises", %{page: page} do
      any = Promise.any([fail(page, "boom"), Promise.async(fn -> raise ArgumentError, "bug" end)])
      assert_raise Playwright.AggregateError, fn -> Promise.await(any) end
    end

    test "plain values are resolved; local promises of the runtime are inputs too", %{page: page} do
      assert Promise.await!(Promise.all([1, later(page, "slow"), nil])) == [1, "slow", nil]
      local = Playwright.Runtime.Promise.async(fn -> Page.evaluate!(page, "() => 2") end)
      assert Promise.await!(Promise.race([local, never(page)])) == 2
    end

    test "the argument must be a list" do
      assert_raise ArgumentError, "Playwright.Promise.race/1 expects a list, got: nil", fn ->
        Promise.race(Enum.random([nil]))
      end
    end
  end
end
