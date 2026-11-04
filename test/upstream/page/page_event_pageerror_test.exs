defmodule PlaywrightEx.Page.PageEventPageerrorTest do
  @upstream "tests/page/page-event-pageerror.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  @tag skip: "not ported: waitForEvent"
  test "should fire"

  @tag skip: "not ported: waitForEvent"
  test "should not receive console message for pageError"

  @tag skip: "not ported: waitForEvent"
  test "should contain sourceURL"

  @tag skip: "not ported: waitForEvent"
  test "should contain the Error.name property"

  @tag skip: "not ported: waitForEvent"
  test "should support an empty Error.name property"

  @tag skip: "not ported: waitForEvent"
  test "should handle odd values"

  @tag skip: "not ported: waitForEvent"
  test "should handle object"

  @tag skip: "not ported: waitForEvent"
  test "should handle window"

  test "should remove a listener of a non-existing event handler", %{page: page} do
    Page.remove_listener(page, :page_error, fn _ -> nil end)
  end

  @tag skip: "not ported: waitForEvent"
  test "should emit error from unhandled rejects"

  test "pageErrors should work", %{page: page} do
    Page.evaluate!(page, """
    async () => {
      for (let i = 0; i < 301; i++)
        window.builtins.setTimeout(() => { throw new Error('error' + i); }, 0);
      await new Promise(f => window.builtins.setTimeout(f, 2000));
    }
    """)

    errors = Page.page_errors!(page)
    messages = Enum.map(errors, & &1.message)

    expected = for i <- 201..300, do: "error#{i}"

    assert length(messages) >= 100, "should be at least 100 errors"
    assert Enum.take(messages, -length(expected)) == expected, "should return last errors"
  end

  test "clearPageErrors should work", %{page: page} do
    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => { throw new Error('error1'); }, 0);
      window.builtins.setTimeout(() => { throw new Error('error2'); }, 0);
    }
    """)

    Page.wait_for_timeout!(page, 1000)

    errors = Page.page_errors!(page)
    assert "error1" in Enum.map(errors, & &1.message)
    assert "error2" in Enum.map(errors, & &1.message)

    Page.clear_page_errors!(page)

    errors = Page.page_errors!(page)
    assert errors == []

    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => { throw new Error('error3'); }, 0);
    }
    """)

    Page.wait_for_timeout!(page, 1000)

    errors = Page.page_errors!(page)
    assert length(errors) == 1
    assert Enum.at(errors, 0).message =~ "error3"
  end

  @tag skip: "not ported: waitForEvent"
  test "should fire illegal character error"
end
