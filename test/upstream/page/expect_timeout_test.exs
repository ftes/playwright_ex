defmodule PlaywrightEx.Page.ExpectTimeoutTest do
  @upstream "tests/page/expect-timeout.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.Errors.TimeoutError
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page

  @moduletag :page

  test "should print element not found", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "no-such-thing"), "hey", timeout: 1000)

    assert error.message =~ """
           expect(locator).toHaveText(expected) failed

           Locator: locator('no-such-thing')
           Expected: "hey"
           Timeout: 1000ms
           Error: element(s) not found

           Call log:
           """
  end

  test "should print timed out error message when value does not match", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "div"), "hey", timeout: 1000)

    assert error.message =~ """
           expect(locator).toHaveText(expected) failed

           Locator:  locator('div')
           Expected: "hey"
           Received: "Text content"
           Timeout:  1000ms

           Call log:
           """
  end

  test "should print timed out error message with impossible timeout", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "no-such-thing"), "hey", timeout: 1)

    assert error.message =~ """
           expect(locator).toHaveText(expected) failed

           Locator: locator('no-such-thing')
           Expected: "hey"
           Timeout: 1ms
           Error: element(s) not found

           Call log:\
           """
  end

  test "should print timed out error message when value does not match with impossible timeout", %{page: page} do
    Page.set_content!(page, "<div id=node>Text content</div>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "div"), "hey", timeout: 1)

    assert error.message =~ """
           expect(locator).toHaveText(expected) failed

           Locator:  locator('div')
           Expected: "hey"
           Received: "Text content"
           Timeout:  1ms

           Call log:
           """
  end

  test "should have timeout error name", %{page: page} do
    {:error, error} = Page.wait_for_selector(page, "#not-found", timeout: 1)
    assert %TimeoutError{} = error
  end

  test "should not throw when navigating during one-shot check", %{page: page, server: server} do
    Page.set_content!(page, "<div>hello</div>")
    promise = Task.async(fn -> Expect.to_have_text!(Page.locator(page, "div"), "bye") end)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<div>bye</div>")
    assert Task.await(promise, :infinity) == :ok
  end

  test "should not throw when navigating during first locator handler check", %{page: page, server: server} do
    Page.add_locator_handler!(page, Page.locator(page, "span"), fn _locator -> :ok end)
    Page.set_content!(page, "<div>hello</div>")
    promise = Task.async(fn -> Expect.to_have_text!(Page.locator(page, "div"), "bye") end)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<div>bye</div>")
    Task.await(promise, :infinity)
  end

  test "should timeout during first locator handler check", %{page: page} do
    Page.add_locator_handler!(page, Page.locator(page, "div"), fn _locator -> :ok end)
    Page.set_content!(page, "<div>hello</div><span>bye</span>")
    {:error, error} = Expect.to_have_text(Page.locator(page, "span"), "bye", timeout: 3000)

    assert error.message =~ """
           expect(locator).toHaveText(expected) failed

           Locator:  locator('span')
           Expected: "bye"
           Received: ""
           Timeout:  3000ms

           Call log:
           """

    assert error.message =~ "locator handler has finished, waiting for locator('div') to be hidden"
    assert error.message =~ "locator resolved to visible <div>hello</div>"
  end

  test "should not miss element that appears between retries before the deadline", %{page: page} do
    Page.set_content!(page, ~s|<div id="target" style="display:none">content</div>|)

    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => {
        document.getElementById('target').style.display = 'block';
      }, 1500);
    }
    """)

    Expect.to_be_visible!(Page.locator(page, "#target"), timeout: 1800)
  end

  @tag skip: "not ported: AbortSignal"
  test "should fail like a timeout when the signal is aborted mid-assertion"

  @tag skip: "not ported: AbortSignal"
  test "should fail like a timeout when toHaveText is aborted mid-assertion"

  @tag skip: "not ported: AbortSignal"
  test "should fail like a timeout when toHaveCount is aborted mid-assertion"

  @tag skip: "not ported: AbortSignal"
  test "should fail like a timeout when toMatchAriaSnapshot is aborted mid-assertion"

  @tag skip: "not ported: AbortSignal"
  test "should fail like a timeout when toHaveURL is aborted mid-assertion"

  @tag skip: "not ported: AbortSignal"
  test "should fail the assertion when the signal is already aborted"
end
