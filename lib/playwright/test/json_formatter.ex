# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Test.JSONFormatter do
  @moduledoc """
  Playwright Test's `json` reporter as an ExUnit formatter: one JSON report of the run, written
  when the suite finishes. It prints nothing else, so it runs next to `ExUnit.CLIFormatter`:

      mix test --formatter ExUnit.CLIFormatter --formatter Playwright.Test.JSONFormatter

  `--formatter` replaces the configured formatters, so name `ExUnit.CLIFormatter` too. Or add it
  in `test/test_helper.exs`:

      ExUnit.start(formatters: [ExUnit.CLIFormatter, Playwright.Test.JSONFormatter])

  The report goes to the first of:

    * `PLAYWRIGHT_JSON_OUTPUT_FILE`, a path;
    * `config :playwright, :test, json_output_file: "test-results/results.json"`, upstream's
      `reporter: [['json', { outputFile }]]`;
    * `PLAYWRIGHT_JSON_OUTPUT_NAME` in `PLAYWRIGHT_JSON_OUTPUT_DIR` (default: the working
      directory);
    * else standard output, as upstream's without an output file.

  Relative paths are relative to the working directory.

  The report has upstream's `JSONReport` shape: `config`, `suites` (a suite per test file
  relative to `test/`, the `rootDir`, with a suite per `describe`), each with its `specs` (a
  test, its `tests` one per project of `parameterize:`), each test's `results`, `errors` (a
  failed `setup_all`) and `stats`. A result has its `status` (`passed`, `failed`, `timedOut`,
  `skipped`), `duration` (ms, ExUnit's time of the test and its setup), `errors` (ExUnit's text
  of each failure, without its header, and its location in your code), `error` (the first, as
  upstream's `TestError`: `message` and `stack`, or `value` for an exit or throw), `steps`
  (those of `Playwright.Test.step/2,3`, nested), `retry` and `attachments`: upstream's
  `name`, `contentType` and `path` (absolute) or `body` (base64), the `Playwright.Test.attach/2`
  ones and the artifacts' (`trace`, `screenshot`, `video`, `error-context`), complete when ExUnit
  reports the test. A test not run after a failed `setup_all` has no results; an excluded one is
  left out.

      # Each test's status and trace (a describe's specs are in its file suite's `suites`).
      report = JSON.decode!(File.read!("test-results/results.json"))

      for file <- report["suites"], suite <- [file | file["suites"] || []], spec <- suite["specs"],
          test <- spec["tests"], result <- test["results"],
          %{"name" => "trace", "path" => path} <- result["attachments"],
          do: {spec["title"], result["status"], path}

  A test of a module without `use Playwright.Test` has ExUnit's fields only: no steps or
  attachments, and its start time is its end less its duration.

  ExUnit has no retries in a run: `retry` is 1 under `mix test --failed`, as
  `Playwright.Test.info/0`'s, and a test passing there is `flaky`, as in
  `Playwright.Test.GitHubFormatter`. Not ported: `stdout` and `stderr` are empty, `annotations`
  and `tags` (ExUnit's tags aren't Playwright's) too; the results have no `workerIndex`,
  `parallelIndex` or `shardIndex` (ExUnit runs modules, not workers); the `config` has only
  `rootDir`, `version`, `workers`, `maxFailures`, `preserveOutput`, `reportSlowTests`,
  `metadata` and the projects the tests ran in (without `testIgnore` and `testMatch`).
  """

  # Upstream's `JSONReporter` (`packages/playwright/src/reporters/json.ts`), with `JSONReport`'s
  # types (`packages/playwright/types/testReporter.d.ts`) and what it uses of `reporters/base.ts`
  # (`resolveOutputFile`). `this` is the GenServer's state. A test's Playwright fields come from
  # `Playwright.Test`'s end of the test, in its `on_exit` (`put_result/4`), which ExUnit runs
  # before it reports the test: a row of this formatter's table, which it takes on
  # `test_finished`.

  use GenServer

  alias Playwright.Test.GitHubFormatter
  alias Playwright.Test.Options
  alias Playwright.Test.TestInfo

  @doc false
  # Whether a JSON formatter runs (its table exists), for `Playwright.Test` to keep a test's
  # steps and result.
  def listening?, do: :ets.whereis(__MODULE__) != :undefined

  @doc false
  # The end of the registered test `test` (`Playwright.Test.__finish__/2`): its `status`
  # (`Playwright.Test.info/1`'s), `attachments` (`Playwright.Test.TestInfo.attachments/1`) and
  # `steps` (`TestInfo.take_steps/1`), for its `test_finished`.
  def put_result(test, status, attachments, steps) do
    if listening?() do
      result = %{
        status: status,
        retry: test.retry,
        start_time: test.start_time,
        timeout: test.test_timeout,
        attachments: attachments,
        steps: steps
      }

      :ets.insert(__MODULE__, {test.report_key, result})
    end

    :ok
  rescue
    # The formatter stopped meanwhile.
    ArgumentError -> :ok
  end

  # constructor
  @impl true
  def init(opts) do
    :ets.new(__MODULE__, [:named_table, :public, :set])
    config = Options.config()

    {:ok,
     %{
       resolved_output_file: resolve_output_file(config.json_output_file),
       # onConfigure: `config`, what of it the report has.
       config: config,
       max_failures: opts[:max_failures],
       timeout: if(opts[:trace], do: :infinity, else: opts[:timeout]),
       # Elixir only: the run's `result.retry`, and the deps for the errors' locations, as
       # `Playwright.Test.GitHubFormatter`'s.
       retry: TestInfo.retry(opts[:only_test_ids]),
       deps: Keyword.get_lazy(opts, :json_formatter_deps, &GitHubFormatter.deps/0),
       # onBegin: the suite, here its tests as ExUnit reports them (newest first).
       tests: [],
       # onError
       errors: [],
       start_time: System.os_time(:millisecond)
     }}
  end

  # version, printsToStdio  -- not ported: ExUnit runs only the formatters it is given

  @impl true
  def handle_cast({:suite_started, _opts}, this), do: {:noreply, %{this | start_time: System.os_time(:millisecond)}}

  # Elixir only: an excluded test is not part of the run, as upstream's filtered-out test.
  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _}}}, this), do: {:noreply, this}

  def handle_cast({:test_finished, %ExUnit.Test{} = test}, this) do
    result =
      case :ets.take(__MODULE__, {test.module, test.name, test.parameters}) do
        [{_key, result}] -> result
        [] -> nil
      end

    # Elixir only: the end of a test without `Playwright.Test`'s start, for its `startTime`.
    {:noreply, %{this | tests: [{test, result, System.os_time(:millisecond)} | this.tests]}}
  end

  # onError: a failed `setup_all`, as upstream's failed global setup.
  def handle_cast({:module_finished, %ExUnit.TestModule{state: {:failed, failures}} = module}, this),
    do: {:noreply, %{this | errors: this.errors ++ [GitHubFormatter.format_error({module, failures})]}}

  def handle_cast({:suite_finished, times_us}, this) do
    on_end(this, times_us)
    {:noreply, this}
  end

  def handle_cast(_event, this), do: {:noreply, this}

  defp on_end(this, times_us), do: output_report(serialize_report(this, times_us), this.resolved_output_file)

  defp serialize_report(this, times_us) do
    tests =
      this.tests
      |> Enum.reverse()
      |> Enum.map(fn {test, result, end_time} -> serialize_test_entry(this, test, result, end_time) end)

    %{
      config: %{
        # ...removePrivateFields(this.config): what maps to ExUnit and `config :playwright, :test`.
        rootDir: TestInfo.test_dir(),
        version: Playwright.Driver.version(),
        workers: this.config.workers,
        maxFailures: if(this.max_failures in [nil, :infinity], do: 0, else: this.max_failures),
        preserveOutput: this.config.preserve_output |> to_string() |> String.replace("_", "-"),
        reportSlowTests: report_slow_tests(this.config.report_slow_tests),
        metadata: %{},
        projects:
          for name <- projects(tests) do
            %{
              outputDir: Path.expand(this.config.output_dir),
              repeatEach: 1,
              # ExUnit has no retries in a run.
              retries: 0,
              metadata: %{},
              id: name,
              name: name,
              testDir: TestInfo.test_dir(),
              # testIgnore, testMatch  -- not ported: Mix's `test_paths` and `test_pattern`
              timeout: timeout(this.timeout)
            }
          end
      },
      suites: merge_suites(tests),
      errors: this.errors,
      stats: %{
        startTime: iso_string(this.start_time),
        # The run's duration, as ExUnit's "Finished in" (load included).
        duration: (times_us.run + (times_us[:load] || 0)) / 1000,
        expected: Enum.count(tests, &(&1.test.status == "expected")),
        skipped: Enum.count(tests, &(&1.test.status == "skipped")),
        unexpected: Enum.count(tests, &(&1.test.status == "unexpected")),
        flaky: Enum.count(tests, &(&1.test.status == "flaky"))
      }
    }
  end

  # The projects of the tests' `parameterize:` (the default project's name is `""`), by name.
  defp projects([]), do: [""]
  defp projects(tests), do: tests |> Enum.map(& &1.test.projectName) |> Enum.uniq() |> Enum.sort()

  defp report_slow_tests(false), do: :null
  defp report_slow_tests(options), do: Map.new(options)

  # The file suites of the tests: `_mergeSuites`, one per file, its tests' specs merged per
  # project (`_mergeTestsFromSuite`) and the specs of each `describe` as a suite of its own
  # (`_serializeSuite`), in the files' order, by line.
  defp merge_suites(tests) do
    tests
    |> Enum.group_by(& &1.file)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {file, entries} ->
      {specs, described} = Enum.split_with(entries, &(&1.describe == nil))

      suites =
        described
        |> Enum.group_by(& &1.describe)
        |> Enum.sort_by(fn {{_title, line}, _entries} -> line end)
        |> Enum.map(fn {{title, line}, entries} ->
          %{title: title, file: file, line: line, column: 0, specs: serialize_specs(entries)}
        end)

      suite = %{title: file, file: file, column: 0, line: 0, specs: serialize_specs(specs)}
      if suites == [], do: suite, else: Map.put(suite, :suites, suites)
    end)
  end

  # `_serializeTestSpec`, the specs of one title and location merged: their tests in turn, the
  # first one's `ok` and `id` (`toSpec.tests.push(...spec.tests)`).
  defp serialize_specs(entries) do
    entries
    |> Enum.group_by(&{&1.title, &1.line})
    |> Enum.sort_by(fn {{_title, line}, _entries} -> line end)
    |> Enum.map(fn {{title, line}, [first | _] = entries} ->
      %{
        title: title,
        ok: first.ok,
        # test.tags  -- not ported: ExUnit's tags are not Playwright's `@tag`s
        tags: [],
        tests: Enum.map(entries, & &1.test),
        id: first.id,
        file: first.file,
        line: line,
        column: 0
      }
    end)
  end

  # A test, with what its spec and suites need: its `file` (`_relativeLocation`), `describe`
  # (`{title, line}`, or `nil`), `title`, `line`, `ok` and `id`.
  defp serialize_test_entry(this, test, result, end_time) do
    # `test.titlePath()`: the file, the describe block, the test.
    [_file | titles] = TestInfo.title_path(Map.put(test.tags, :test, test.name))
    file = Path.relative_to(Path.expand(test.tags.file), TestInfo.test_dir(), force: true)
    project_name = TestInfo.project_name(test.parameters)
    outcome = GitHubFormatter.outcome(this, test)

    %{
      file: file,
      describe: if(describe = test.tags[:describe], do: {describe, test.tags[:describe_line] || 0}),
      title: List.last(titles),
      line: test.tags.line,
      # `test.ok()`
      ok: outcome != :unexpected,
      id: test_id(file, titles, project_name),
      test: serialize_test(this, test, result, end_time, project_name, outcome)
    }
  end

  # suiteUtils.ts `bindFileSuiteToProject`'s `test.id`.
  defp test_id(file, titles, project_id) do
    file_id = binary_part(TestInfo.calculate_sha1(file), 0, 20)
    test_id_expression = "[project=#{project_id}]#{file}\x1e#{Enum.join(titles, "\x1e")}"
    file_id <> "-" <> binary_part(TestInfo.calculate_sha1(test_id_expression), 0, 20)
  end

  defp serialize_test(this, test, result, end_time, project_name, outcome) do
    %{
      timeout: timeout(if(result, do: result.timeout, else: Options.ex_unit_timeout(test.tags))),
      # test.annotations  -- not ported: annotations
      annotations: [],
      expectedStatus: if(match?({:skipped, _}, test.state), do: "skipped", else: "passed"),
      projectId: project_name,
      projectName: project_name,
      # A test not run after a failed `setup_all` has no result, as upstream's did-not-run test.
      results:
        if(match?({:invalid, _}, test.state), do: [], else: [serialize_test_result(this, test, result, end_time)]),
      status: Atom.to_string(outcome)
    }
  end

  defp serialize_test_result(this, test, result, end_time) do
    duration = div(test.time, 1000)
    errors = if match?({:failed, _}, test.state), do: GitHubFormatter.format_result_failure(this, test), else: []
    error = first_error(test, errors)

    json_result = %{
      # workerIndex, parallelIndex  -- not ported: ExUnit runs modules, not workers
      status: status(test, result),
      duration: duration,
      error: error,
      errors: Enum.map(errors, &serialize_error/1),
      # stdout, stderr  -- not ported: the test's stdout and stderr
      stdout: [],
      stderr: [],
      retry: result[:retry] || this.retry,
      steps: serialize_test_steps(result[:steps]),
      # Without `Playwright.Test`'s start, its end less its duration.
      startTime: iso_string(result[:start_time] || end_time - duration),
      # result.annotations  -- not ported: annotations
      annotations: [],
      attachments:
        for a <- result[:attachments] || [] do
          %{name: a.name, contentType: a.contentType, path: a[:path], body: a[:body] && Base.encode64(a.body)}
        end
    }

    if error[:stack], do: Map.put(json_result, :errorLocation, error.location), else: json_result
  end

  # `result.status`: ExUnit's, a failure past the test's timeout `timedOut` (`Playwright.Test`'s
  # `timed_out`, or ExUnit's timeout).
  defp status(%ExUnit.Test{state: state}, result) do
    case state do
      nil ->
        "passed"

      {:failed, failures} ->
        timed_out? =
          match?(%{status: :timed_out}, result) or Enum.any?(failures, &match?({_, %ExUnit.TimeoutError{}, _}, &1))

        if timed_out?, do: "timedOut", else: "failed"

      _skipped ->
        "skipped"
    end
  end

  # `result.error`: the first failure as a `TestError` (`testInfoError`), at its location.
  defp first_error(%ExUnit.Test{state: {:failed, [failure | _]}}, [%{location: location} | _]),
    do: Map.put(TestInfo.test_info_error(failure), :location, location && Map.put(location, :column, 0))

  defp first_error(_test, _errors), do: nil

  # `_serializeError`: `formatError(nonTerminalScreen, error)`, ExUnit's text of the failure.
  defp serialize_error(%{message: message, location: location}),
    do: %{message: message, location: location && Map.put(location, :column, 0)}

  # `result.steps.filter(s => s.category === 'test.step')`, each `_serializeTestStep`.
  defp serialize_test_steps(steps) do
    case for(step <- steps || [], step.category == "test.step", do: step) do
      [] -> nil
      steps -> Enum.map(steps, &serialize_test_step/1)
    end
  end

  defp serialize_test_step(step),
    do: %{
      title: step.title,
      subtitle: step.subtitle,
      duration: step.duration,
      error: step.error,
      steps: serialize_test_steps(step.steps)
    }

  # An ExUnit timeout in ms, `0` for none (`:infinity`), as upstream's.
  defp timeout(timeout) when is_integer(timeout), do: timeout
  defp timeout(_infinity), do: 0

  # `Date.prototype.toISOString`.
  defp iso_string(ms), do: ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()

  # `JSON.stringify(report, undefined, 2)`: written to the file, or printed.
  defp output_report(report, resolved_output_file) do
    report_string = stringify(report)

    if resolved_output_file do
      File.mkdir_p!(Path.dirname(resolved_output_file))
      File.write!(resolved_output_file, report_string)
    else
      IO.puts(report_string)
    end
  end

  # `nil` is `undefined`, left out, and `:null` is `null`. Indented by `:json.format/1` (OTP 27).
  defp stringify(report) do
    json = JSON.encode!(json_value(report))

    if Code.ensure_loaded?(:json) and function_exported?(:json, :format, 1),
      do: IO.iodata_to_binary(:json.format(:json.decode(json))),
      else: json
  end

  defp json_value(:null), do: nil

  defp json_value(%{} = map) when not is_struct(map),
    do: for({key, value} <- map, value != nil, into: %{}, do: {key, json_value(value)})

  defp json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  defp json_value(value), do: value

  # base.ts `resolveOutputFile('JSON', options)`, with the working directory as `configDir`: the
  # json reporter has no `default`.
  defp resolve_output_file(output_file) do
    cond do
      file = resolve_from_env("PLAYWRIGHT_JSON_OUTPUT_FILE") ->
        file

      output_file ->
        Path.expand(output_file)

      true ->
        output_dir = resolve_from_env("PLAYWRIGHT_JSON_OUTPUT_DIR") || File.cwd!()

        case System.get_env("PLAYWRIGHT_JSON_OUTPUT_NAME") do
          report_name when report_name in [nil, ""] -> nil
          report_name -> Path.expand(report_name, output_dir)
        end
    end
  end

  # base.ts `resolveFromEnv`.
  defp resolve_from_env(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> nil
      value -> Path.expand(value)
    end
  end
end
