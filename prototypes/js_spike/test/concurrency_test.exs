# Spike 8: N processes x M evaluate calls on separate pages and on one page: no deadlock,
# wall time vs sequential, and how long a call holds the baton.
defmodule PlaywrightJS.ConcurrencyTest do
  use ExUnit.Case, async: false
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Runtime.Baton
  alias PlaywrightJS.Client.{BrowserContext, Page}

  @n 20
  @m 50

  defp baton(page), do: page.conn |> Map.get(:pid) |> Baton.get()

  defp run(pages, label) do
    baton = baton(hd(pages))
    Baton.reset_stats(baton)

    {us, results} =
      :timer.tc(fn ->
        pages
        |> Enum.with_index()
        |> Enum.map(fn {page, i} -> Task.async(fn -> for j <- 1..@m, do: Page.evaluate(page, "([i, j]) => i * 1000 + j", [i, j]) end) end)
        |> Task.await_many(60_000)
      end)

    for {result, i} <- Enum.with_index(results), do: assert(result == Enum.map(1..@m, &(i * 1000 + &1)))
    report(label, us, Baton.stats(baton))
  end

  defp sequential(page) do
    baton = baton(page)
    Baton.reset_stats(baton)
    {us, _} = :timer.tc(fn -> for j <- 1..(@n * @m), do: Page.evaluate(page, "(j) => j", j) end)
    report("sequential (1 process, #{@n * @m} calls)", us, Baton.stats(baton))
  end

  defp report(label, us, stats) do
    calls = @n * @m
    holds = stats |> Map.values() |> Enum.map(& &1.count) |> Enum.sum()
    held = stats |> Map.values() |> Enum.map(& &1.total_us) |> Enum.sum()

    kinds =
      Enum.map_join(stats, ", ", fn {kind, s} -> "#{kind}: #{s.count}x mean #{Float.round(s.total_us / s.count, 1)}us max #{s.max_us}us" end)

    IO.puts(
      "\n#{label}: wall #{div(us, 1000)}ms (#{Float.round(us / calls, 1)}us/call), " <>
        "baton held #{div(held, 1000)}ms total = #{Float.round(held / calls, 1)}us/call over #{Float.round(holds / calls, 1)} holds/call " <>
        "(#{Float.round(100 * held / us, 1)}% of wall)\n  #{kinds}"
    )

    us
  end

  @tag timeout: 300_000
  test "#{@n} processes x #{@m} evaluates: separate pages, one page, sequential" do
    %{context: context, page: page} = env = TestHelper.launch()
    pages = [page | for(_ <- 2..@n, do: BrowserContext.new_page(context))]

    # warm-up
    for p <- pages, do: Page.evaluate(p, "1")

    seq = sequential(page)
    separate = run(pages, "#{@n} processes, separate pages")
    one = run(List.duplicate(page, @n), "#{@n} processes, one page")
    IO.puts("speedup vs sequential: separate pages #{Float.round(seq / separate, 1)}x, one page #{Float.round(seq / one, 1)}x")
    assert separate < seq
    TestHelper.close(env)
  end
end
