defmodule PlaywrightEx.Client.JSHandleDisposeTest do
  # Not mirrored from upstream: an explicitly disposed JSHandle frees its rows (JS: GC frees it once
  # unreferenced), so a long-lived page does not grow with the handles it disposed.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page
  alias PlaywrightEx.TargetClosedError

  @moduletag :page

  defp rows(page), do: :ets.info(page.table, :size)

  defp settle(page, rows, attempts \\ 40) do
    if rows(page) - rows <= 10 or attempts == 0,
      do: rows(page),
      else: Process.sleep(50) && settle(page, rows, attempts - 1)
  end

  test "1000 disposed handles leave the row count flat", %{page: page} do
    Page.set_content!(page, "<section>39</section>")
    # Warm up: the first calls create objects of the page and the connection.
    Page.evaluate_handle!(page, "() => ({})") |> JSHandle.dispose!()
    JSHandle.dispose!(Page.query_selector!(page, "section"))
    rows = rows(page)

    for _ <- 1..500 do
      JSHandle.dispose!(Page.evaluate_handle!(page, "() => ({})"))
      JSHandle.dispose!(Page.query_selector!(page, "section"))
    end

    assert settle(page, rows) - rows <= 10
  end

  test "a disposed handle raises as in JS, and disposes twice", %{page: page} do
    handle = Page.evaluate_handle!(page, "() => ({a: 1})")
    JSHandle.dispose!(handle)
    assert_raise TargetClosedError, fn -> JSHandle.evaluate!(handle, "h => h.a") end
    assert_raise TargetClosedError, fn -> JSHandle.get_property!(handle, "a") end
    assert JSHandle.dispose!(handle) == :ok
  end

  test "handles of a closed page stay readable", %{page: page} do
    handle = Page.evaluate_handle!(page, "() => 42")
    Page.close!(page)
    assert to_string(handle) == "42"
  end
end
