defmodule PlaywrightEx.Page.PageListenersTest do
  @upstream "tests/page/page-listeners.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import ExUnit.CaptureLog

  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.Runtime.EventLoop

  @moduletag :page

  # `new ManualPromise()`: a runtime promise (the public API creates none). A call without
  # `await` is `Runtime.Promise.async/1` (it returns at the call's first suspension point).
  defp manual_promise(page), do: EventLoop.with_baton(page.loop, fn -> Runtime.Promise.new() end)

  # This test is mostly for type checking, the actual tests are in the library/events.

  test "should not throw with ignoreErrors", %{page: page} do
    reached_handler = manual_promise(page)
    release_handler = manual_promise(page)

    Page.on(page, :console, fn _ ->
      Runtime.Promise.resolve(reached_handler, nil)
      PlaywrightEx.Promise.await!(release_handler)
      raise "Error in console handler"
    end)

    Page.evaluate!(page, "console.log(1)")
    PlaywrightEx.Promise.await!(reached_handler)

    log =
      capture_log(fn ->
        Page.remove_all_listeners!(page, :console, behavior: :ignore_errors)
        Runtime.Promise.resolve(release_handler, nil)
        Page.wait_for_timeout!(page, 1000)
      end)

    refute log =~ "Error in console handler"
  end

  test "should wait", %{page: page} do
    reached_handler = manual_promise(page)
    release_handler = manual_promise(page)
    test = self()

    Page.on(page, :console, fn _ ->
      Runtime.Promise.resolve(reached_handler, nil)
      send(test, {:value, 42})
    end)

    Page.evaluate!(page, "console.log(1)")
    PlaywrightEx.Promise.await!(reached_handler)
    remove_promise = Runtime.Promise.async(fn -> Page.remove_all_listeners!(page, :console, behavior: :wait) end)
    Runtime.Promise.resolve(release_handler, nil)
    PlaywrightEx.Promise.await!(remove_promise)
    assert_received {:value, 42}
  end

  test "wait should throw", %{page: page} do
    reached_handler = manual_promise(page)
    release_handler = manual_promise(page)

    Page.on(page, :console, fn _ ->
      Runtime.Promise.resolve(reached_handler, nil)
      PlaywrightEx.Promise.await!(release_handler)
      raise "Error in handler"
    end)

    Page.evaluate!(page, "console.log(1)")
    PlaywrightEx.Promise.await!(reached_handler)
    remove_promise = Runtime.Promise.async(fn -> Page.remove_all_listeners!(page, :console, behavior: :wait) end)
    Runtime.Promise.resolve(release_handler, nil)
    assert {:error, error} = PlaywrightEx.Promise.await(remove_promise)
    assert Exception.message(error) =~ "Error in handler"
  end
end
