# Spike 1: the baton runtime. Client code runs in the calling process under one token per
# driver; await releases it; dispatch hands it to listeners; holders that crash are reclaimed.
defmodule PlaywrightJS.BatonTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Runtime.{Baton, Promise}
  alias PlaywrightJS.Client.{Errors, Page}

  defp baton(page), do: Baton.get(page.conn.pid)

  test "client code runs in the caller; the baton is not held between API calls" do
    %{page: page} = env = TestHelper.launch()
    refute Baton.held?()
    assert Page.evaluate(page, "1 + 1") == 2
    refute Baton.held?()
    TestHelper.close(env)
  end

  test "check-then-subscribe is atomic: waitForLoadState/waitForURL never miss the event" do
    %{page: page} = env = TestHelper.launch()

    for i <- 1..60 do
      url = TestHelper.fixture_url("result.html") <> "?name=n#{i}"
      navigation = Promise.async(fn -> Page.goto(page, url, %{waitUntil: "commit"}) end)
      Page.wait_for_load_state(page, "load", %{timeout: 5000})
      Page.wait_for_url(page, ~r/#{Regex.escape("?name=n#{i}")}$/, %{timeout: 5000})
      Promise.await(navigation)
    end

    TestHelper.close(env)
  end

  test "no dispatch while a sync section holds the baton" do
    %{page: page} = env = TestHelper.launch()
    flag = :ets.new(:flag, [:public])
    Page.on(page, "console", fn _ -> :ets.insert(flag, {:seen}) end)
    evaluation = Promise.async(fn -> Page.evaluate(page, "console.log(1), 1") end)

    Baton.with_baton(baton(page), fn ->
      before = :ets.member(flag, :seen)
      # The console event and the evaluate response arrive meanwhile, but wait for the baton.
      Process.sleep(300)
      assert before == :ets.member(flag, :seen)
    end)

    assert Promise.await(evaluation) == 1
    assert :ets.member(flag, :seen)
    TestHelper.close(env)
  end

  test "a process killed while holding the baton is reclaimed" do
    %{page: page} = env = TestHelper.launch()
    baton = baton(page)
    test = self()

    holder =
      spawn(fn ->
        Baton.acquire(baton)
        send(test, :holding)
        Process.sleep(:infinity)
      end)

    assert_receive :holding

    log =
      capture_log(fn ->
        Process.exit(holder, :kill)
        assert Page.evaluate(page, "40 + 2") == 42
      end)

    assert log =~ "died"
    TestHelper.close(env)
  end

  test "a crashing or exiting listener is logged; dispatch and callers continue" do
    %{page: page} = env = TestHelper.launch()
    test = self()
    Page.on(page, "console", fn _ -> raise "listener boom" end)
    Page.on(page, "console", fn _ -> exit(:bye) end)
    Page.on(page, "console", fn message -> send(test, {:third, PlaywrightJS.Client.ConsoleMessage.text(message)}) end)

    log =
      capture_log(fn ->
        assert Page.evaluate(page, "console.log('x'), 7") == 7
        assert_received {:third, "x"}
      end)

    assert log =~ "listener boom"
    assert Page.evaluate(page, "8") == 8
    TestHelper.close(env)
  end

  test "zones: a listener does not inherit the caller's API zone" do
    %{page: page} = env = TestHelper.launch()
    test = self()

    Page.on(page, "console", fn _ ->
      e =
        try do
          Page.wait_for_event(page, "popup", %{timeout: 50})
        rescue
          e -> e
        end

      send(test, {:listener_error, e})
    end)

    Page.evaluate(page, "console.log('z')")
    assert_receive {:listener_error, %Errors.TimeoutError{message: "page.waitForEvent: Timeout 50ms" <> _}}, 5000
    TestHelper.close(env)
  end
end
