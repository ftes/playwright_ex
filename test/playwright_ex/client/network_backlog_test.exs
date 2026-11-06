defmodule PlaywrightEx.Client.NetworkBacklogTest do
  # Not mirrored from upstream (OTP_BACKLOG): route `complete` latches are freed, interception
  # patterns are computed when they are sent, and concurrent `allHeaders` share one call.
  @upstream nil
  # The send hook (`{Conn, :on_send}`) is global.
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.Page
  alias PlaywrightEx.Response
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime.Conn

  @moduletag :page

  # The page's rows, without its child objects (`_objects`: requests stay until the driver
  # collects them, as in JS).
  defp page_rows(page) do
    keys = :ets.select(page.table, [{{{page.guid, :"$1"}, :_}, [], [:"$1"]}])
    Enum.count(keys, &(not match?({:map, :_objects, _}, &1)))
  end

  defp record_sent(method) do
    test = self()

    :persistent_term.put({Conn, :on_send}, fn message ->
      if message.method == method, do: send(test, {:sent, message})
    end)

    on_exit(fn -> :persistent_term.erase({Conn, :on_send}) end)
  end

  defp sent(acc \\ []) do
    receive do
      {:sent, message} -> sent([message | acc])
    after
      200 -> Enum.reverse(acc)
    end
  end

  test "handled routes leave no rows on the page", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    Page.route!(page, "**/fulfill", fn route -> Route.fulfill(route, body: "ok") end)
    Page.evaluate!(page, "() => fetch('/fulfill')")
    rows = page_rows(page)

    Page.evaluate!(page, "async () => { for (let i = 0; i < 100; i++) await fetch('/fulfill'); }")

    # Back to the baseline or below (a browser may free rows of its own meanwhile).
    assert page_rows(page) <= rows
  end

  test "concurrent routes send the patterns of all of them", %{page: page} do
    record_sent("setNetworkInterceptionPatterns")

    1..20
    |> Enum.map(fn i -> Task.async(fn -> Page.route!(page, "**/r#{i}", fn route -> Route.continue(route) end) end) end)
    |> Task.await_many()

    last = sent() |> Enum.filter(&(&1.guid == page.guid)) |> List.last()
    assert length(last.params.patterns) == 20
  end

  test "concurrent allHeaders share one rawResponseHeaders call", %{page: page, server: server} do
    response = Page.goto!(page, server.empty_page)
    record_sent("rawResponseHeaders")

    headers =
      1..10
      |> Enum.map(fn _ -> Task.async(fn -> Response.all_headers!(response) end) end)
      |> Task.await_many()

    assert length(Enum.uniq(headers)) == 1
    assert length(sent()) == 1
  end
end
