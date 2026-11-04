# Spike 2: listeners run synchronously inside dispatch, before the caller's await resumes.
defmodule PlaywrightJS.OrderingTest do
  use ExUnit.Case, async: false
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Client.{ConsoleMessage, Locator, Page}

  @iterations 300

  test "console listener has run before evaluate returns (#{@iterations} iterations)" do
    %{page: page} = env = TestHelper.launch()
    seen = :ets.new(:seen, [:public, :ordered_set])
    Page.on(page, "console", fn message -> :ets.insert(seen, {String.to_integer(ConsoleMessage.text(message))}) end)

    for i <- 1..@iterations do
      Page.evaluate(page, "console.log(#{i})")
      # No waiting: the listener must already have run.
      assert :ets.member(seen, i), "iteration #{i}: listener had not run when evaluate returned"
    end

    assert :ets.info(seen, :size) == @iterations
    TestHelper.close(env)
  end

  test "async listener awaits Playwright calls inside the listener" do
    %{page: page} = env = TestHelper.launch()
    Page.goto(page, TestHelper.fixture_url("form.html"))
    test = self()
    log = :ets.new(:log, [:public, :duplicate_bag])

    Page.on(page, "console", fn message ->
      # Synchronous part: runs before the evaluate that logged returns.
      :ets.insert(log, {:started, ConsoleMessage.text(message)})
      # Awaits: the baton goes back to dispatch, the listener resumes later.
      title = Page.title(page)
      heading = page |> Page.locator("h1") |> Locator.text_content()
      sum = Page.evaluate(page, "1 + 2")
      send(test, {:listener_done, ConsoleMessage.text(message), title, heading, sum})
    end)

    for i <- 1..20 do
      Page.evaluate(page, "console.log('m#{i}')")
      assert :ets.member(log, :started) and {:started, "m#{i}"} in :ets.lookup(log, :started)
    end

    for i <- 1..20 do
      assert_receive {:listener_done, text, "Sign up", "Sign up", 3}, 5000
      assert text == "m#{i}"
    end

    TestHelper.close(env)
  end

  test "waitForEvent registered by an un-awaited async call before the trigger" do
    %{page: page} = env = TestHelper.launch()

    for i <- 1..50 do
      promise = PlaywrightJS.Runtime.Promise.async(fn -> Page.wait_for_event(page, "console") end)
      Page.evaluate(page, "console.log('w#{i}')")
      assert ConsoleMessage.text(PlaywrightJS.Runtime.Promise.await(promise)) == "w#{i}"
    end

    TestHelper.close(env)
  end
end
