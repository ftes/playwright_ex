defmodule PlaywrightEx.Page.WorkersTest do
  @upstream "tests/page/workers.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Worker

  @moduletag :page

  @blob_worker """
  () => {
    window.worker = new Worker(URL.createObjectURL(new Blob(['42'], { type: 'application/javascript' })));
  }
  """

  @tag skip: "not ported: waitForEvent"
  test "Page.workers @smoke"

  @tag skip: "not ported: waitForEvent, evaluateHandle"
  test "should emit created and destroyed events"

  @tag skip: "not ported: waitForEvent"
  test "should report console logs"

  @tag skip: "not ported: waitForEvent"
  test "should have timestamp on worker console messages"

  @tag skip: "not ported: waitForEvent"
  test "should not report console logs from workers twice"

  @tag skip: "not ported: JSHandle.getProperty"
  test "should have JSHandles for console logs"

  @tag skip: "not ported: waitForEvent"
  test "should evaluate"

  test "should report console event on the worker", %{page: page} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    worker =
      Page.expect_event!(page, :worker, fn ->
        Page.evaluate!(page, @blob_worker)
      end)

    promises = [
      Worker.wait_for_event(worker, :console),
      Page.wait_for_event(page, :console),
      BrowserContext.wait_for_event(Page.context(page), :console)
    ]

    Worker.evaluate!(worker, "() => { console.log('hello from worker'); }")
    [message1, message2, message3] = Enum.map(promises, &Promise.await!/1)
    assert ConsoleMessage.text(message1) == "hello from worker"
    assert message1 == message2
    assert message1 == message3
  end

  test "should report console event on the worker when not listening on page or context", %{page: page} do
    # it.skip(browserName === 'chromium' && browserMajorVersion < 143, ...)  -- the pinned browsers are newer
    worker =
      Page.expect_event!(page, :worker, fn ->
        Page.evaluate!(page, @blob_worker)
      end)

    message =
      Worker.expect_event!(worker, :console, fn ->
        Worker.evaluate!(worker, "() => { console.log('hello from worker'); }")
      end)

    assert ConsoleMessage.text(message) == "hello from worker"
  end

  test "should report errors", %{page: page} do
    test = self()
    Page.on(page, :page_error, fn error -> send(test, {:pageerror, error}) end)

    Page.evaluate!(page, """
    () => new Worker(URL.createObjectURL(new Blob([`
      setTimeout(() => {
        // Do a console.log just to check that we do not confuse it with an error.
        console.log('hey');
        throw new Error('this is my error');
      })
    `], { type: 'application/javascript' })))
    """)

    assert_receive {:pageerror, error_log}, 5000
    assert error_log.message =~ "this is my error"
  end

  @tag skip: "not ported: waitForEvent"
  test "should clear upon navigation"

  @tag skip: "not ported: waitForEvent"
  test "should clear upon cross-process navigation"

  @tag skip: "not ported: waitForEvent, evaluateHandle (attachFrame)"
  test "should attribute network activity for worker inside iframe to the iframe"

  @tag skip: "not ported: waitForEvent"
  test "should report network activity"

  @tag skip: "not ported: waitForRequest"
  test "should report network activity on worker creation"

  @tag skip: "not ported: waitForEvent"
  test "should report worker script as network request"

  @tag skip: "not ported: waitForEvent"
  test "should report worker script as network request after redirect"

  @tag skip: "not ported: waitForEvent"
  test "should dispatch console messages when page has workers"

  @tag skip: "not ported: expect.poll"
  test "should report and intercept network from nested worker"

  @tag skip: "not ported: waitForEvent"
  test "should support extra http headers"

  @tag skip: "not ported: waitForEvent"
  test "should support offline"

  @tag skip: "not ported: waitForEvent"
  test "should resolve worker script allHeaders in main frame"

  @tag skip: "not ported: waitForEvent, evaluateHandle (attachFrame)"
  test "should resolve worker script allHeaders in iframe"

  @tag skip: "not ported: waitForEvent, evaluateHandle (attachFrame)"
  test "should resolve worker script allHeaders in nested worker inside iframe"
end
