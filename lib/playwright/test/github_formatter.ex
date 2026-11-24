# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Test.GitHubFormatter do
  @moduledoc """
  Playwright Test's `github` reporter as an ExUnit formatter: GitHub Actions annotations for
  failed tests, errors outside a test, slow test files and the run's summary. It prints only
  workflow commands, so it runs next to `ExUnit.CLIFormatter`, on CI, as upstream's documented
  `reporter: process.env.CI ? 'github' : 'list'`:

      mix test --formatter ExUnit.CLIFormatter --formatter Playwright.Test.GitHubFormatter

  `--formatter` replaces the configured formatters, so name `ExUnit.CLIFormatter` (and any of
  your own) too. A CI that reruns failed tests (`mix test || { [ $? -eq 2 ] && mix test
  --failed; }`) passes it to both runs, as upstream annotates every attempt. Or add it in
  `test/test_helper.exs`:

      github = if System.get_env("GITHUB_ACTIONS"), do: [Playwright.Test.GitHubFormatter], else: []
      ExUnit.start(formatters: [ExUnit.CLIFormatter | github])

  It prints:

    * an `::error` for each failure of a failed test, at the first frame of its stacktrace in
      your code (not Playwright's, ExUnit's, Elixir's, Erlang/OTP's or a dependency's under
      `deps/`; a path dependency is yours), else on the test's file, titled
      `file:line › describe › test`, with ExUnit's failure text, under `Retry #1` on the rerun.
    * an `::error` for each failed `setup_all`; its tests count as not run.
    * a `Slow Test` `::warning` for each of the 5 slowest files whose tests took more than
      5 minutes (upstream's `reportSlowTests`: `config :playwright, :test, report_slow_tests:
      [max: 5, threshold: 300_000]` in ms, `false` for none).
    * a `🎭 Playwright Run Summary` `::notice`: the failed and flaky tests, the counts of
      skipped, not run and passed tests, and the run's duration.

  ExUnit has no retries in a run: a test under `mix test --failed` is upstream's retry 1 (as
  `Playwright.Test.info/0`'s `retry`), so one that passes there is flaky. Each run prints its
  own summary, and a flaky test keeps the first run's `::error`, as upstream's flaky test does.
  Unlike upstream, a test not run after a failed `setup_all` that passes on the rerun counts as
  flaky too: the failures manifest doesn't record why a test is in it.

  Paths are relative to `GITHUB_WORKSPACE`. It reads only ExUnit's events: any ExUnit suite
  can use it, with or without `Playwright.Test`.
  """

  # Upstream's `GitHubReporter` (`packages/playwright/src/reporters/github.ts`), with what it uses
  # of its base class `TerminalReporter` (`reporters/base.ts`), on a screen without colors or tty
  # width (100 columns). `this` is the GenServer's state. A run's tests are all of one attempt:
  # retry 0, or retry 1 under `mix test --failed`, where a passing test's earlier result (a
  # failure) is the first run's.

  use GenServer

  alias Playwright.Isomorphic.StringUtils
  alias Playwright.Test.TestInfo

  # ExUnit's width without a tty, for its failure text.
  @width 80

  # class GitHubLogger

  # newLine  -- ported as the newline before each command in `log/3`

  # _log; debug, error, notice, warning  -- ported as its `type` argument
  defp log(message, type, options) do
    configs = Enum.map_join(options, ",", fn {key, option} -> "#{key}=#{escape_property(to_string(option))}" end)
    # deviation: one write that starts on a line of its own. GitHub reads a command only at the
    # start of a line, and ExUnit.CLIFormatter, a process of its own, may have written a `.`
    # without a newline (Node's one thread has the reporters write in turn).
    IO.write(StringUtils.strip_ansi_escapes("\n::#{type} #{configs}::#{escape_data(message)}\n"))
  end

  # Same escaping as @actions/core, see https://github.com/actions/toolkit/blob/main/packages/core/src/command.ts.
  defp escape_data(s), do: s |> String.replace("%", "%25") |> String.replace("\r", "%0D") |> String.replace("\n", "%0A")

  defp escape_property(s), do: s |> escape_data() |> String.replace(":", "%3A") |> String.replace(",", "%2C")

  # class GitHubReporter

  # constructor: `omitTags`  -- not ported: ExUnit's tags are not Playwright's `@tag`s
  @impl true
  def init(opts) do
    # Elixir only: upstream's `reportSlowTests` is `config :playwright, :test`'s.
    %{report_slow_tests: report_slow_tests} = Playwright.Test.Options.config()

    # TerminalReporter's `suite` (the tests, newest first), `fileDurations` and
    # `config.reportSlowTests`; GitHubReporter's `_failedTestCount`.
    {:ok,
     %{
       tests: [],
       file_durations: %{},
       report_slow_tests: report_slow_tests,
       failed_test_count: 0,
       duration: 0,
       # Elixir only: the run's `result.retry` (ExUnit passes its configuration, `only_test_ids`
       # included).
       retry: TestInfo.retry(opts[:only_test_ids]),
       # Elixir only: where the deps live, for `belongsToNodeModules` (`location/2`). Tests pass
       # their own.
       deps: Keyword.get_lazy(opts, :github_formatter_deps, &deps/0)
     }}
  end

  # printsToStdio  -- not ported: ExUnit runs only the formatters it is given (add ExUnit.CLIFormatter)

  @impl true
  # Elixir only: an excluded test is not part of the run, as upstream's filtered-out test.
  def handle_cast({:test_finished, %ExUnit.Test{state: {:excluded, _}}}, this), do: {:noreply, this}
  def handle_cast({:test_finished, %ExUnit.Test{} = test}, this), do: {:noreply, on_test_end(this, test)}

  # Elixir only: a failed `setup_all` is an error outside a test, as upstream's failed global setup.
  def handle_cast({:module_finished, %ExUnit.TestModule{state: {:failed, failures}} = module}, this) do
    on_error({module, failures})
    {:noreply, this}
  end

  def handle_cast({:suite_finished, times_us}, this), do: {:noreply, on_end(this, times_us)}
  def handle_cast(_event, this), do: {:noreply, this}

  defp on_test_end(this, test) do
    this = terminal_reporter_on_test_end(this, test)
    # if (this.willRetry(test)) return;  -- not ported: ExUnit has no retries
    if should_print_failure_annotations(this, test) do
      this = %{this | failed_test_count: this.failed_test_count + 1}
      # this.githubLogger.newLine();  -- in `log/3`
      # for (const r of test.results): this run's result.
      print_failure_annotation(this, test, this.failed_test_count)
      this
    else
      this
    end
  end

  # deviation: not 'flaky': its failed result is the first run's, which numbered and annotated it,
  # so the rerun's numbers have no gaps.
  # 'skipped' with an interrupted result  -- never: no interruption
  defp should_print_failure_annotations(this, test), do: outcome(this, test) == :unexpected

  @doc false
  # Elixir only: `test.outcome()` of the test's results, this run's and, on a retry, the first
  # run's failure before it (`--failed` reruns only failures). Also `Playwright.Test.JSONFormatter`'s.
  # deviation: a test not run after a failed `setup_all` is in the failures manifest too, without
  # its state, so one passing on the rerun is flaky, where upstream's did-not-run-then-passed test
  # is expected (`computeTestCaseOutcome`).
  def outcome(this, %ExUnit.Test{state: state}) do
    case state do
      nil when this.retry > 0 -> :flaky
      nil -> :expected
      {:failed, _} -> :unexpected
      # A skipped test, or one not run after a failed `setup_all`.
      _ -> :skipped
    end
  end

  defp on_end(this, times_us) do
    # `super.onEnd(result)`: `result.duration`, the run's, as ExUnit's "Finished in" (load included).
    this = %{this | duration: (times_us.run + (times_us[:load] || 0)) / 1000}
    print_annotations(this)
    this
  end

  # Upstream's does not call `super.onError`: `_fatalErrors` stays empty.
  defp on_error(error) do
    error_message = format_error(error).message
    log(error_message, :error, [])
  end

  defp print_annotations(this) do
    summary = generate_summary(this)
    summary_message = generate_summary_message(this, summary)
    print_slow_test_annotations(this)
    print_summary_annotation(summary_message)
  end

  defp print_slow_test_annotations(this) do
    # The `[project] › file` key joined to the cwd, as upstream's.
    Enum.each(get_slow_tests(this), fn {file, duration} ->
      file_path = workspace_relative_path(Path.join(File.cwd!(), file))
      log("#{file_path} took #{ms_to_string(duration)}", :warning, title: "Slow Test", file: file_path)
    end)
  end

  defp print_summary_annotation(summary), do: log(summary, :notice, title: "🎭 Playwright Run Summary")

  defp print_failure_annotation(this, test, index) do
    title = format_test_title(test)
    header = format_test_header(test, indent: "  ", index: index, mode: :error)
    errors = format_result_failure(this, test)

    for error <- errors do
      options = [
        file: workspace_relative_path(if(error.location, do: error.location.file, else: test.tags.file)),
        title: title
      ]

      # `options.col = error.location.column`  -- not ported: ExUnit's stacktraces have no column
      options = if error.location, do: options ++ [line: error.location.line], else: options
      message = Enum.join([header | format_retry(this)] ++ [error.message], "\n")
      log(message, :error, options)
    end
  end

  defp workspace_relative_path(file_path),
    do: Path.relative_to(Path.expand(file_path), Path.expand(System.get_env("GITHUB_WORKSPACE", "")), force: true)

  # class TerminalReporter

  defp terminal_reporter_on_test_end(this, test) do
    # ++this._failureCount  -- not ported: only the line and dot reporters read it
    project_name = project_name(test)
    relative_path = relative_test_path(test)
    file_and_project = if(project_name, do: "[#{project_name}] › ", else: "") <> relative_path
    {duration, workers} = Map.get(this.file_durations, file_and_project, {0, MapSet.new()})
    # A module's tests run one at a time, as a worker's: the module is the worker.
    entry = {duration + test.time / 1000, MapSet.put(workers, test.module)}
    %{this | tests: [test | this.tests], file_durations: Map.put(this.file_durations, file_and_project, entry)}
  end

  defp get_slow_tests(%{report_slow_tests: false}), do: []

  defp get_slow_tests(%{report_slow_tests: report_slow_tests} = this) do
    # Only pick durations that were served by single worker.
    file_durations =
      for {key, {duration, workers}} <- this.file_durations, MapSet.size(workers) == 1, do: {key, duration}

    file_durations = Enum.sort_by(file_durations, &elem(&1, 1), :desc)
    max = report_slow_tests[:max]
    count = if max in [nil, 0], do: length(file_durations), else: min(length(file_durations), max)
    threshold = report_slow_tests[:threshold]
    file_durations |> Enum.filter(fn {_, duration} -> duration > threshold end) |> Enum.take(count)
  end

  defp generate_summary_message(this, %{did_not_run: did_not_run, skipped: skipped, expected: expected} = summary) do
    tokens = [
      if(summary.unexpected != [],
        do: [
          "  #{length(summary.unexpected)} failed"
          | Enum.map(summary.unexpected, &format_test_header(&1, indent: "    "))
        ]
      ),
      # interrupted  -- never: no interruption
      if(summary.flaky != [],
        do: ["  #{length(summary.flaky)} flaky" | Enum.map(summary.flaky, &format_test_header(&1, indent: "    "))]
      ),
      if(skipped > 0, do: "  #{skipped} skipped"),
      if(did_not_run > 0, do: "  #{did_not_run} did not run"),
      if(expected > 0, do: "  #{expected} passed (#{ms_to_string(this.duration)})")
      # fatalErrors  -- never: GitHubReporter's onError does not collect them
    ]

    tokens |> List.flatten() |> Enum.reject(&is_nil/1) |> Enum.join("\n")
  end

  defp generate_summary(this) do
    # this.suite.allTests(): by file and line.
    tests = this.tests |> Enum.reverse() |> Enum.sort_by(&{&1.tags.file, &1.tags.line})

    summary =
      Enum.reduce(tests, %{did_not_run: 0, skipped: 0, expected: 0, unexpected: [], flaky: []}, fn test, summary ->
        case {outcome(this, test), test.state} do
          # 'skipped' with expectedStatus 'skipped'
          {:skipped, {:skipped, _}} -> %{summary | skipped: summary.skipped + 1}
          # 'skipped' with expectedStatus 'passed': not run after a failed `setup_all`, as upstream's
          # after a failed `beforeAll`.
          {:skipped, {:invalid, _}} -> %{summary | did_not_run: summary.did_not_run + 1}
          {:expected, _} -> %{summary | expected: summary.expected + 1}
          {:unexpected, _} -> %{summary | unexpected: [test | summary.unexpected]}
          {:flaky, _} -> %{summary | flaky: [test | summary.flaky]}
        end
      end)

    # failuresToPrint  -- not ported: only `epilogue` prints them
    %{summary | unexpected: Enum.reverse(summary.unexpected), flaky: Enum.reverse(summary.flaky)}
  end

  # formatTestTitle: `test.titlePath()` is `Playwright.Test`'s (the file, the describe block,
  # the test), the project its `Playwright.Test.parameters/1` name.
  defp format_test_title(test) do
    [_file | titles] = TestInfo.title_path(Map.put(test.tags, :test, test.name))
    # ExUnit has no column.
    location = "#{relative_test_path(test)}:#{test.tags.line}"
    # testId  -- not ported: includeTestId, an option of the merge reporter
    project_title = if name = project_name(test), do: "[#{name}] › ", else: ""
    # extraTags, stepSuffix(step)  -- not ported: no `@tag`s, no step
    "#{project_title}#{location} › #{Enum.join(titles, " › ")}"
  end

  defp format_test_header(test, options) do
    title = format_test_title(test)
    header = "#{options[:indent]}#{if options[:index], do: "#{options[:index]}) "}#{title}"
    # mode 'error': the path to the deepest failing test.step  -- not ported: ExUnit's events have no steps
    separator(header)
  end

  @doc false
  # formatError: ExUnit's text of a failed `setup_all`, without its counter. Also
  # `Playwright.Test.JSONFormatter`'s.
  def format_error({module, failures}) do
    text = ExUnit.Formatter.format_test_all_failure(module, failures, 1, @width, &formatter/2)
    %{message: text |> String.replace_prefix("  1) ", "") |> String.trim_trailing()}
  end

  # formatRetry: the run's `result.retry`.
  defp format_retry(%{retry: 0}), do: []
  defp format_retry(%{retry: retry}), do: ["", separator("    Retry ##{retry}")]

  @doc false
  # formatResultFailure: ExUnit's failure text (`ExUnit.Formatter.format_test_failure/5`, without
  # its header, which upstream's replaces) for formatError's message, already indented, and its
  # location. Also `Playwright.Test.JSONFormatter`'s (`this.deps`).
  # 'Expected to fail, but passed.', 'Test was interrupted.'  -- never: no `test.fail`, no
  # interruption.
  def format_result_failure(this, %ExUnit.Test{state: {:failed, failures}} = test) do
    # The header alone: the text of no failures.
    header = ExUnit.Formatter.format_test_failure(test, [], 1, @width, &formatter/2)

    for {_kind, _reason, stack} = failure <- failures do
      text = ExUnit.Formatter.format_test_failure(test, [failure], 1, @width, &formatter/2)
      message = text |> String.replace_prefix(header, "") |> String.trim_trailing()
      %{message: message, location: location(this.deps, stack)}
    end
  end

  # `parsedStack.location` of `filterStackTrace`'s stack: its first frame outside the runner's and
  # the client's code (`filterStackFile`) that is not a dependency's (`parseErrorStack`'s
  # `belongsToNodeModules`).
  defp location(deps, stack) do
    Enum.find_value(stack, fn
      {module, _fun, _arity, location} when is_list(location) ->
        with file when file != nil <- location[:file],
             line when line != nil <- location[:line],
             true <- user_code?(deps, module) do
          %{file: source_file(module, to_string(file)), line: line}
        else
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  # A module of no app (a test's `.exs`) or of the project is the user's, not the runner's or the
  # client's, nor Erlang/OTP's or Elixir's (an app under either's root, apart in a mise or asdf
  # install); a dependency's is when its source is outside the deps path (a path dependency, an
  # umbrella sibling).
  defp user_code?(deps, module) do
    case :application.get_application(module) do
      :undefined -> true
      {:ok, :playwright} -> false
      {:ok, app} -> !(under?(:code.lib_dir(app), system_roots()) or dependency?(deps, app))
    end
  end

  defp system_roots, do: [:code.root_dir(), Path.dirname(to_string(:code.lib_dir(:elixir)))]

  defp under?({:error, :bad_name}, _roots), do: false
  defp under?(dir, roots), do: Enum.any?(roots, &String.starts_with?(Path.expand(dir) <> "/", Path.expand(&1) <> "/"))

  defp dependency?(nil, _app), do: false

  defp dependency?(deps, app),
    do: deps.paths[app] != nil and String.starts_with?(deps.paths[app] <> "/", deps.path <> "/")

  # A frame's file is relative to its app's root (a path dependency's `lib/x.ex`): the module's
  # absolute source, when the frame is in it (not in code a macro of another file brought in).
  defp source_file(module, file) do
    source = to_string(module.module_info(:compile)[:source])

    if Path.type(file) == :relative and String.ends_with?(source, "/" <> file),
      do: source,
      else: Path.expand(file)
  end

  @doc false
  # `%{paths: %{app => dir}, path: deps_dir}` of the Mix project, or `nil` without one (every
  # app's frames are then the user's).
  def deps do
    if Code.ensure_loaded?(Mix.Project) and Process.whereis(Mix.ProjectStack) != nil and Mix.Project.get() != nil do
      %{
        paths: Map.new(Mix.Project.deps_paths(), fn {app, dir} -> {app, Path.expand(dir)} end),
        path: Mix.Project.deps_path()
      }
    end
  end

  # No colors and no diff, as ExUnit.CLIFormatter's without colors.
  defp formatter(:diff_enabled?, _), do: false
  defp formatter(_key, value), do: value

  defp relative_test_path(test), do: Path.relative_to(Path.expand(test.tags.file), File.cwd!(), force: true)

  # `test.titlePath()[1]`: the name of the module's `Playwright.Test.parameters/1` project, `nil`
  # for an unnamed one or none (upstream's `""`).
  defp project_name(%ExUnit.Test{parameters: parameters}) do
    case TestInfo.project_name(parameters) do
      "" -> nil
      name -> name
    end
  end

  defp separator(text) do
    text = if text != "", do: text <> " ", else: text
    text <> String.duplicate("─", max(0, 100 - String.length(StringUtils.strip_ansi_escapes(text))))
  end

  # msToString (`packages/isomorphic/formatUtils.ts`).
  defp ms_to_string(ms) when ms < 0, do: "-"
  defp ms_to_string(ms) when ms == 0, do: "0ms"
  defp ms_to_string(ms) when ms < 1000, do: "#{round(ms)}ms"
  defp ms_to_string(ms) when ms < 60_000, do: to_fixed(ms / 1000) <> "s"
  defp ms_to_string(ms) when ms < 3_600_000, do: to_fixed(ms / 60_000) <> "m"
  defp ms_to_string(ms) when ms < 86_400_000, do: to_fixed(ms / 3_600_000) <> "h"
  defp ms_to_string(ms), do: to_fixed(ms / 86_400_000) <> "d"

  defp to_fixed(x), do: :erlang.float_to_binary(x / 1, decimals: 1)
end
