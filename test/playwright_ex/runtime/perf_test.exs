defmodule PlaywrightEx.RuntimePerfTest do
  # Performance of the runtime against the baton baseline (PLAN Phase 2): the public facade only,
  # so the same file runs on the baton revision. Manual only (`mix test --only perf`; excluded by
  # default). Each scenario runs in a process that exits before the "after" numbers, as a test
  # process would. Results: one JSON line per scenario, appended to `PERF_OUT` (default
  # tmp/perf.jsonl) with `PERF_LABEL`.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  @moduletag :perf
  @moduletag :page
  @moduletag timeout: 900_000

  test "5k evaluate_handle on one page, then dispose", %{browser: browser, page: page} do
    run("handles_5k", page, fn ->
      context = Browser.new_context!(browser)
      page = BrowserContext.new_page!(context)
      Page.evaluate!(page, "1")
      rows = rows(page)
      {handles, calls} = timed(1..5000, fn _ -> Page.evaluate_handle!(page, "() => ({})") end)
      {_, disposes} = timed(handles, &JSHandle.dispose!/1)
      Process.sleep(200)
      after_dispose = rows(page)
      BrowserContext.close!(context)

      %{
        calls: calls,
        extra: %{dispose: summary(disposes), rows_before_handles: rows, rows_after_dispose: after_dispose}
      }
    end)
  end

  test "1000 pages (10 contexts x 100), then close", %{browser: browser, page: page} do
    run("pages_1000", page, fn ->
      {contexts, _} =
        timed(1..10, fn _ ->
          context = Browser.new_context!(browser)
          {_, calls} = timed(1..100, fn _ -> BrowserContext.new_page!(context) end)
          {context, calls}
        end)

      {_, closes} = timed(Enum.map(contexts, &elem(&1, 0)), &BrowserContext.close!/1)
      %{calls: Enum.flat_map(contexts, &elem(&1, 1)), extra: %{close: summary(closes)}}
    end)
  end

  test "2000 sequential evaluate", %{page: page} do
    Page.evaluate!(page, "1")

    run("evaluate_2000", page, fn ->
      {_, calls} = timed(1..2000, fn _ -> Page.evaluate!(page, "1") end)
      %{calls: calls}
    end)
  end

  test "10 concurrent callers x 200 evaluate", %{page: page} do
    Page.evaluate!(page, "1")

    run("concurrent_10x200", page, fn ->
      calls =
        1..10
        |> Enum.map(fn _ -> Task.async(fn -> elem(timed(1..200, fn _ -> Page.evaluate!(page, "1") end), 1) end) end)
        |> Task.await_many(300_000)
        |> Enum.concat()

      %{calls: calls}
    end)
  end

  test "context close time vs row count", %{browser: browser, page: page} do
    for n <- [0, 1000, 5000] do
      run("close_vs_rows_#{n}", page, fn ->
        context = Browser.new_context!(browser)
        page = BrowserContext.new_page!(context)
        for _ <- 1..n//1, do: Page.evaluate_handle!(page, "() => ({})")
        rows = rows(page)
        {_, [close]} = timed([context], &BrowserContext.close!/1)
        %{calls: [close], extra: %{rows_at_close: rows}}
      end)
    end
  end

  ## Measuring

  # Runs `body` in a process that exits, sampling memory, processes and rows meanwhile; writes the
  # numbers. `body` returns `%{calls: [{duration_us, completed_at_us}], extra: map}`.
  defp run(name, page, body) do
    settle()
    before = snapshot(page)
    sampler = spawn_link(fn -> sample(page, before) end)
    started = now()
    result = Task.await(Task.async(body), 900_000)
    elapsed = now() - started
    send(sampler, {:stop, self()})
    peak = receive do: ({:peak, peak} -> peak)
    settle()
    after_ = snapshot(page)

    line =
      %{
        label: System.get_env("PERF_LABEL", "unlabelled"),
        scenario: name,
        total_ms: div(elapsed, 1000),
        calls: summary(result.calls),
        max_gap_ms: max_gap(started, result.calls),
        before: before,
        peak: peak,
        after: after_
      }
      |> Map.merge(Map.get(result, :extra, %{}))

    path = System.get_env("PERF_OUT", "tmp/perf.jsonl")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(line) <> "\n", [:append])
    IO.puts(JSON.encode!(line))
  end

  defp timed(enum, fun) do
    enum
    |> Enum.map(fn item ->
      t0 = now()
      value = fun.(item)
      t1 = now()
      {value, {t1 - t0, t1}}
    end)
    |> Enum.unzip()
  end

  defp summary([]), do: nil

  defp summary(calls) do
    sorted = calls |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, floor(q * n))) / 1000 end
    %{n: n, p50_ms: at.(0.5), p99_ms: at.(0.99), max_ms: List.last(sorted) / 1000}
  end

  # The longest time without a completion (from the start), in ms.
  defp max_gap(started, calls) do
    calls
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort()
    |> Enum.reduce({started, 0}, fn t, {previous, gap} -> {t, max(gap, t - previous)} end)
    |> elem(1)
    |> Kernel./(1000)
  end

  defp snapshot(page) do
    %{ets_bytes: :erlang.memory(:ets), processes: :erlang.system_info(:process_count), rows: rows(page)}
  end

  defp sample(page, peak) do
    receive do
      {:stop, from} -> send(from, {:peak, peak})
    after
      10 ->
        now = snapshot(page)

        sample(
          page,
          Map.merge(peak, now, fn _key, a, b -> if is_integer(a) and is_integer(b), do: max(a, b), else: b end)
        )
    end
  end

  # The OTP runtime's connection table (rows of all objects); nil on the baton runtime.
  defp rows(page) do
    case Map.get(page, :table) do
      nil -> nil
      table -> :ets.info(table, :size)
    end
  end

  defp settle do
    Process.sleep(200)
    :erlang.garbage_collect()
  end

  defp now, do: System.monotonic_time(:microsecond)
end
