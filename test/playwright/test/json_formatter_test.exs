defmodule Playwright.Test.JSONFormatterTest.Projects do
  @moduledoc false
  # A module of tests with `parameterize:` projects b and a, as ExUnit's runner reads it.
  def __ex_unit__(:config),
    do: %{parameterize: [Playwright.Test.parameters(name: "b"), Playwright.Test.parameters(name: "a")]}
end

defmodule Playwright.Test.JSONFormatterTest do
  # Not async: it sets the `PLAYWRIGHT_JSON_*` env vars and the formatter's config, and its
  # formatters' table is named. The report of a real run: `Playwright.Test.EndToEndTest`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Playwright.Test.JSONFormatter

  @env ~w(PLAYWRIGHT_JSON_OUTPUT_FILE PLAYWRIGHT_JSON_OUTPUT_DIR PLAYWRIGHT_JSON_OUTPUT_NAME)

  setup do
    env = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    config = Application.get_env(:playwright, :test, [])

    on_exit(fn ->
      for {name, value} <- env, do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
      Application.put_env(:playwright, :test, config)
    end)

    %{config: config}
  end

  @tag :tmp_dir
  test "the output file: the env's, else the config's, else the env's name in its dir, else stdout",
       %{config: config, tmp_dir: tmp_dir} do
    in_tmp = &Path.join(tmp_dir, &1)
    File.cd!(tmp_dir, fn -> File.mkdir_p!("out") end)

    Application.put_env(:playwright, :test, Keyword.put(config, :json_output_file, in_tmp.("config.json")))
    System.put_env("PLAYWRIGHT_JSON_OUTPUT_FILE", in_tmp.("env.json"))
    System.put_env("PLAYWRIGHT_JSON_OUTPUT_DIR", in_tmp.("out"))
    System.put_env("PLAYWRIGHT_JSON_OUTPUT_NAME", "named.json")

    assert run([]) == ""
    assert %{"suites" => [], "stats" => %{"expected" => 0}} = JSON.decode!(File.read!(in_tmp.("env.json")))

    System.delete_env("PLAYWRIGHT_JSON_OUTPUT_FILE")
    run([])
    assert File.exists?(in_tmp.("config.json"))

    Application.put_env(:playwright, :test, config)
    run([])
    assert File.exists?(in_tmp.("out/named.json"))

    System.delete_env("PLAYWRIGHT_JSON_OUTPUT_NAME")
    assert %{"config" => %{"rootDir" => _}} = JSON.decode!(run([]))
  end

  test "a test's projects are one spec's tests; a failure's text and location, a timeout, a rerun's pass" do
    {failure, line} = {failure(fn -> raise "oops" end), __ENV__.line}
    project = &Playwright.Test.parameters(name: &1)

    report =
      report([
        test_struct("test pays", parameters: project.("b"), state: {:failed, [failure]}),
        test_struct("test pays", parameters: project.("a")),
        test_struct("test waits",
          line: 20,
          state: {:failed, [{:error, %ExUnit.TimeoutError{timeout: 10, type: "test"}, []}]}
        )
      ])

    assert %{"stats" => %{"expected" => 1, "unexpected" => 2}, "config" => %{"projects" => projects}} = report
    assert Enum.map(projects, & &1["name"]) == ["", "a", "b"]

    file = Path.relative_to(__ENV__.file, Path.join(File.cwd!(), "test"))
    # The first project's specs first (the default project, `""`, has `waits`), as upstream merges them.
    assert [%{"file" => ^file, "specs" => [waits, pays]}] = report["suites"]
    # Without `parameterize:` order, by name: the first project's `ok`, as upstream merges them.
    assert %{"title" => "pays", "ok" => true, "tests" => [a, b]} = pays
    assert %{"projectName" => "b", "status" => "unexpected", "results" => [result]} = b
    assert %{"projectName" => "a", "status" => "expected"} = a

    assert %{"status" => "failed", "retry" => 0, "errors" => [%{"message" => message, "location" => location}]} =
             result

    assert message =~ "** (RuntimeError) oops"
    assert location == %{"file" => __ENV__.file, "line" => line, "column" => 0}
    assert %{"message" => "RuntimeError: oops", "stack" => _, "location" => ^location} = result["error"]
    assert result["errorLocation"] == location

    assert %{"tests" => [%{"results" => [%{"status" => "timedOut"}]}]} = waits

    # Under `mix test --failed`: a retry, whose pass is flaky.
    report = report([test_struct("test pays")], only_test_ids: MapSet.new())

    assert %{"stats" => %{"flaky" => 1}, "suites" => [%{"specs" => [%{"ok" => true, "tests" => [test]}]}]} = report
    assert %{"status" => "flaky", "results" => [%{"retry" => 1}]} = test
  end

  test "a spec's tests are in the order of `parameterize:`, its `ok` and `id` the first project's" do
    project = &Playwright.Test.parameters(name: &1)
    projects = Playwright.Test.JSONFormatterTest.Projects

    a =
      test_struct("test pays",
        module: projects,
        parameters: project.("a"),
        state: {:failed, [failure(fn -> raise "oops" end)]}
      )

    b = test_struct("test pays", module: projects, parameters: project.("b"))

    # As upstream's: the first project's spec, the later's tests added, though one failed.
    spec = fn tests ->
      assert %{"suites" => [%{"specs" => [%{"ok" => ok, "id" => id, "tests" => tests}]}]} = report(tests)
      {ok, id, Enum.map(tests, & &1["projectName"])}
    end

    assert {true, id, ["b", "a"]} = spec.([a, b])
    assert spec.([b, a]) == {true, id, ["b", "a"]}
  end

  test "a binary that isn't UTF-8 raises, with its test, field and value" do
    failure = failure(fn -> flunk("got " <> <<255>>) end)
    {:ok, this} = JSONFormatter.init(json_formatter_table: Module.concat(__MODULE__, Table))

    {:noreply, this} =
      JSONFormatter.handle_cast({:test_finished, test_struct("test pays", state: {:failed, [failure]})}, this)

    message =
      ~s(Playwright.Test.JSONFormatter: the JSON report can't be written, it has a binary that isn't UTF-8 ) <>
        ~s{in test "pays" (#{Path.relative_to(__ENV__.file, Path.join(File.cwd!(), "test"))}:10) at } <>
        ~s{suites[0].specs[0].tests[0].results[0].error.message, got: }

    error =
      assert_raise RuntimeError, fn ->
        JSONFormatter.handle_cast({:suite_finished, %{run: 0, async: 0, load: nil}}, this)
      end

    assert String.starts_with?(error.message, message)
    assert String.ends_with?(error.message, ~S(got: "ExUnit.AssertionError: got \xFF"))
  end

  test "a test without `Playwright.Test`'s start starts at its end less its duration, not the report's" do
    before = System.os_time(:millisecond)
    report = JSON.decode!(run([{:test_finished, %{test_struct("test pays") | time: 30_000}}, {:sleep, 1000}]))

    assert %{"suites" => [%{"specs" => [%{"tests" => [%{"results" => [%{"startTime" => start_time}]}]}]}]} = report
    {:ok, start_time, 0} = DateTime.from_iso8601(start_time)
    start_time = DateTime.to_unix(start_time, :millisecond)
    assert start_time >= before - 30 and start_time < before + 500
  end

  defp report(tests, opts \\ []),
    do: JSON.decode!(run(Enum.map(tests, &{:test_finished, &1}), opts))

  # The report on stdout, or `""`.
  defp run(events, opts \\ []) do
    capture_io(fn ->
      # Its own table: the run's formatter has the default one under `--formatter`.
      opts = Keyword.put_new(opts, :json_formatter_table, Module.concat(__MODULE__, Table))
      {:ok, pid} = GenServer.start(JSONFormatter, opts)
      GenServer.cast(pid, {:suite_started, opts})

      Enum.each(events, fn
        {:sleep, ms} -> Process.sleep(ms)
        event -> GenServer.cast(pid, event)
      end)

      GenServer.cast(pid, {:suite_finished, %{run: 1000, async: 0, load: nil}})
      GenServer.stop(pid)
    end)
  end

  defp failure(fun) do
    fun.()
  rescue
    e -> {:error, e, __STACKTRACE__}
  end

  defp test_struct(name, opts \\ []) do
    name = String.to_atom(name)

    %ExUnit.Test{
      name: name,
      module: Keyword.get(opts, :module, __MODULE__),
      state: Keyword.get(opts, :state),
      time: 0,
      tags: %{file: __ENV__.file, line: Keyword.get(opts, :line, 10), test_type: :test, test: name},
      parameters: Keyword.get(opts, :parameters, %{})
    }
  end
end
