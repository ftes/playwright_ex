defmodule PlaywrightEx.Test.TestInfo do
  @moduledoc false
  # What the runner and the ported matchers need of upstream's `TestInfoImpl`
  # (`packages/playwright/src/worker/testInfo.ts`) for a test of `use PlaywrightEx.Test`: its
  # names and output dir (`titlePath`, `outputDir`, with util.ts's `sanitizeForFilePath` and
  # `trimLongString`), snapshot paths (`_resolveSnapshotPaths`, `snapshotPath`), output paths
  # (`_getOutputPath`) and error list (`_failWithError`), which fails the test when its body
  # ends (`PlaywrightEx.Test.__passed__/0`), and its steps (`_addStep`), traced by its
  # `_tracing` (`PlaywrightEx.Test.TestTracing`).
  #
  # `this` is a map of the test's static fields. Its mutable state, the snapshot indexes, the
  # errors and the steps, are rows of the pool's public table keyed `{:test_info, test_pid, _}`,
  # as a matcher or step may run in another process of the test (`$callers`). The pool deletes
  # them when the test's process ends, and fails the test with the errors left.

  alias PlaywrightEx.Client.ClientStackTrace
  alias PlaywrightEx.Isomorphic.MimeType
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Matchers.Expect
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.Results
  alias PlaywrightEx.Test.TestTracing

  @doc """
  The test's fields: `test_pid`, `file`, `test_name` (`titlePath.slice(1).join(' ')`), `retry`
  (`retry/2`) and `output_dir` (with the retry's suffix).
  """
  def new(context) do
    dir = Path.expand(output_dir(context))
    retry = retry(dir)

    %{
      test_pid: context.test_pid,
      file: Path.expand(context.file),
      test_name: test_name(context),
      retry: retry,
      # `if (this.retry) testOutputDir += '-retry' + this.retry`.
      output_dir: if(retry > 0, do: "#{dir}-retry#{retry}", else: dir),
      # `nextStepId = createCallIdGenerator()`: its prefix.
      step_id_prefix: for(_ <- 1..4, into: "", do: <<Enum.random(?a..?z)>>)
    }
  end

  # `_tracing`: the test's recorder, if it records artifacts.
  defp _tracing(this), do: Recorder.lookup(this.test_pid)

  # The test's names and output dir, from its ExUnit context, as `testInfo`'s constructor
  # (`titlePath`, `outputDir`) and util.ts (`sanitizeForFilePath`, `trimLongString`) make them.

  @doc "A test name without its macro's prefix (`test `, or the context's `test_type`)."
  def test_name(%{test: test} = context),
    do: test |> to_string() |> String.replace_prefix("#{context[:test_type] || :test} ", "")

  @doc "Upstream's `testInfo.titlePath`: the file, the describe block, the test."
  def title_path(%{file: file} = context) do
    name = test_name(context)

    case context[:describe] do
      nil -> [Path.relative_to_cwd(file), name]
      describe -> [Path.relative_to_cwd(file), describe, String.replace_prefix(name, describe <> " ", "")]
    end
  end

  @doc "The output dir of the test of `context` (see `output_dir/5`)."
  def output_dir(%{module: module, file: file} = context),
    do:
      output_dir(PlaywrightEx.Test.Options.output_dir(), file, test_name(context), module, parameters(module, context))

  @doc """
  A test's output dir under `root`, as upstream's `testInfo.outputDir`: the file relative to
  `test/` without `_test.exs`, `/` as `-`, then `-` and the sanitized test `name`, trimmed to 60
  characters (`trimLongString`). Then `-` and a hash of the module and parameters, as upstream
  appends the project: modules of a file, or parameter sets, may share a test name.
  """
  def output_dir(root, file, name, module, parameters) do
    relative =
      file |> relative_test_file() |> String.replace_suffix("_test.exs", "") |> String.replace_suffix(".exs", "")

    name = trim_long_string(String.replace(relative, "/", "-") <> "-" <> sanitize_for_file_path(name), 60)

    Path.join(root, name <> "-" <> short_hash(:erlang.term_to_binary({module, parameters}, [:deterministic])))
  end

  @doc """
  The parameters of `context` in `module` (`%{}` for a module without `parameterize:`), for its
  output dir: a guess, the module's parameter map whose keys have the context's values.
  """
  def parameters(module, context) do
    case parameterize(module) do
      list when is_list(list) -> Enum.find(list, %{}, &(is_map(&1) and Map.take(context, Map.keys(&1)) == &1))
      _ -> %{}
    end
  end

  # `__ex_unit__(:config)` is ExUnit's internal API (`@doc false`; a map with `:parameterize`
  # in 1.18 to 1.20): any other shape is no parameters.
  defp parameterize(module) do
    case Code.ensure_loaded?(module) and function_exported?(module, :__ex_unit__, 1) and module.__ex_unit__(:config) do
      %{parameterize: list} -> list
      _ -> nil
    end
  end

  @doc "Upstream's `testDir`: `test/` of the working directory."
  def test_dir, do: Path.join(File.cwd!(), "test")

  @doc """
  Upstream's `testInfo.retry` of the test whose output dir is `dir` (`output_dir/1`'s). ExUnit
  has no retries, so a test under `mix test --failed` (ExUnit's `only_test_ids`) is the retry
  after the ones it has dirs of, `<dir>-retry1` for none; any other run's is 0.
  """
  # deviation: upstream's retries run in the run of the failure, after its outputDir was cleared.
  def retry(dir, only_test_ids \\ ExUnit.configuration()[:only_test_ids])
  def retry(_dir, nil), do: 0
  def retry(dir, _only_test_ids), do: Enum.max(Map.keys(retry_dirs(dir)), fn -> 0 end) + 1

  @doc """
  Deletes the test's output dir before it runs (workerMain.ts's `removeFolders([testInfo.outputDir])`),
  and a first run's (retry 0) `-retryN` dirs too: upstream deletes all of `outputDir` at the
  start of a run (`createRemoveOutputDirsTask`), here the dirs of the tests that run.
  """
  def remove_output_dirs(this) do
    # deviation: the dirs of tests not run stay, for `mix test --failed`, which needs the
    # failures' dirs of the run before.
    if this.retry == 0, do: for({_retry, dir} <- retry_dirs(this.output_dir), do: File.rm_rf(dir))
    # `removeFolders` ignores errors.
    File.rm_rf(this.output_dir)
    :ok
  end

  # `%{retry => dir}` of the `<dir>-retryN` dirs: a test's dirs, as no other test's ends so
  # (its dir ends in a hash).
  defp retry_dirs(dir) do
    prefix = Path.basename(dir) <> "-retry"

    case File.ls(Path.dirname(dir)) do
      {:ok, names} ->
        for name <- names,
            String.starts_with?(name, prefix),
            retry = String.replace_prefix(name, prefix, ""),
            retry =~ ~r/^[1-9][0-9]*$/,
            into: %{},
            do: {String.to_integer(retry), Path.join(Path.dirname(dir), name)}

      {:error, _} ->
        %{}
    end
  end

  @doc "A test file relative to `test_dir/0`, else to the working directory: the output dir's name."
  def relative_test_file(file) do
    file = Path.expand(file)

    if String.starts_with?(file, test_dir() <> "/"),
      do: Path.relative_to(file, test_dir()),
      else: Path.relative_to(file, File.cwd!())
  end

  @doc "Upstream's `sanitizeForFilePath`."
  def sanitize_for_file_path(s), do: Regex.replace(~r/[\x00-\x2C\x2E-\x2F\x3A-\x40\x5B-\x60\x7B-\x7F]+/, s, "-")

  @doc "Upstream's `trimLongString` (`windowsFilesystemFriendlyLength` is 60)."
  def trim_long_string(s, length \\ 100) do
    if String.length(s) <= length do
      s
    else
      middle = "-#{short_hash(s)}-"
      start = div(length - String.length(middle), 2)
      ending = length - String.length(middle) - start
      String.slice(s, 0, start) <> middle <> String.slice(s, -ending, ending)
    end
  end

  @doc "utils `calculateSha1`: the hex SHA-1 of `data`."
  def calculate_sha1(data), do: :crypto.hash(:sha, data) |> Base.encode16(case: :lower)

  defp short_hash(data), do: binary_part(calculate_sha1(data), 0, 5)

  @doc "Registers the running test `this` (`new/1`, in its `setup`), once: matchers of its processes find it."
  def start(this) do
    :ets.insert_new(Results.table(), {{:test_info, this.test_pid, :info}, this})
    :ok
  end

  @doc """
  Upstream's `expectConfig().testInfo`: the running test of this process, or of a process in its
  `$callers` (a `Task` of the test), else `nil`.
  """
  def current do
    if Results.started?(), do: Enum.find_value([self() | List.wrap(Process.get(:"$callers"))], &lookup/1)
  end

  defp lookup(pid) do
    case :ets.lookup(Results.table(), {:test_info, pid, :info}) do
      [{_key, this}] -> this
      [] -> nil
    end
  end

  @doc """
  The end of the test's body: unregisters it (later matchers run as outside a test) and returns
  its errors (`{kind, reason, stacktrace}`), in the order they were recorded.
  """
  def finish(test_pid) do
    if Results.started?() do
      :ets.delete(Results.table(), {:test_info, test_pid, :info})
      take_errors(test_pid)
    else
      []
    end
  end

  @doc """
  The test's process ended (the pool's `DOWN`): removes its rows and returns the errors the end
  of its body did not take (it never got there).
  """
  def ended(test_pid) do
    errors = finish(test_pid)
    # Not the errors: a late `_fail_with_error/2` takes its own back.
    not_error = {:not, {:andalso, {:is_tuple, :"$1"}, {:==, {:element, 1, :"$1"}, :error}}}
    :ets.select_delete(Results.table(), [{{{:test_info, test_pid, :"$1"}, :_}, [not_error], [true]}])
    errors
  end

  @doc "Takes the errors `_fail_with_error/2` recorded for the test `test_pid`."
  def take_errors(test_pid) do
    # One by one (`take`): a row `_fail_with_error/2` took back is not counted.
    test_pid
    |> error_rows()
    |> Enum.flat_map(fn {key, _error} -> :ets.take(Results.table(), key) end)
    |> in_order()
  end

  @doc """
  `testInfo.errors` while the test `test_pid` runs: the errors `_fail_with_error/2` recorded so
  far (its soft errors), left in place.
  """
  def errors(test_pid), do: if(Results.started?(), do: test_pid |> error_rows() |> in_order(), else: [])

  defp error_rows(test_pid), do: :ets.match_object(Results.table(), {{:test_info, test_pid, {:error, :_}}, :_})

  defp in_order(rows), do: rows |> Enum.sort_by(fn {{_, _, {:error, seq}}, _error} -> seq end) |> Enum.map(&elem(&1, 1))

  # Whether the test runs: the end of its body, and the pool, unregister it before taking its
  # errors and rows.
  defp running?(this), do: lookup(this.test_pid) != nil

  # Elixir only: a row of the test. One written once the test ended (by a process of the test
  # that outlived its body) is removed again, as the pool may have removed its rows.
  defp put_row(this, key, value) do
    :ets.insert(Results.table(), {key, value})
    if !running?(this), do: :ets.delete(Results.table(), key)
  end

  # _findLastPredefinedStep  -- not ported: hooks and fixtures are ExUnit's (no steps)

  # `_parentStep`: the step of the zone.
  defp _parent_step(this) do
    case Zones.data(:stepZone) do
      %{testInfo: %{test_pid: test_pid}} = step when test_pid == this.test_pid -> step
      _ -> nil
    end
  end

  @doc """
  `_addStep`: a step of `data` (`category`, `title`, `subtitle`, `stack`, `params`, `box`,
  `group`; Elixir only: `callSite`, `%{file: _, line: _}` of the step's call), as a map with
  `stepId`, `boxedStack` (an Elixir stacktrace, or `nil`), `stack` (frames) and `testInfo`. Its
  mutable fields are a row of the pool's table.
  """
  def _add_step(this, data, parent_step \\ nil) do
    seq = System.unique_integer([:positive, :monotonic])
    step_id = "#{this.step_id_prefix}@#{seq}"

    # if (data.category === 'hook' || data.category === 'fixture')  -- not ported: hooks and fixtures
    parent_step = parent_step || _parent_step(this)

    boxed_stack = parent_step && parent_step.boxedStack
    stack = data[:stack]

    {boxed_stack, stack} =
      if !boxed_stack and data[:box] do
        boxed_stack = slice_call_site(filtered_stack_trace(capture_raw_stack()), data[:callSite])
        {boxed_stack, stack || stack_frames(boxed_stack)}
      else
        {boxed_stack, stack}
      end

    stack = stack || stack_frames(filtered_stack_trace(capture_raw_stack()))
    group = if(parent_step[:group] != nil, do: parent_step.group, else: data[:group])

    step =
      Map.merge(data, %{
        stepId: step_id,
        group: group,
        boxedStack: boxed_stack,
        stack: stack,
        testInfo: this,
        # Elixir only: the recorder its `before` went to, which its `after` goes to. The test's
        # first context may start its recorder inside the step, and an `after` without its
        # `before` breaks the trace viewer.
        _tracing: if(group != "internal", do: _tracing(this))
      })

    # `info: new TestStepInfoImpl(...)`, `steps: []`; `parentStepList.push(step)`,
    # `this._stepMap.set(stepId, step)`: the row, its parent's `steps` by `parentStepId`.
    put_row(this, step_key(step), %{
      parentStepId: parent_step && parent_step.stepId,
      seq: seq,
      endWallTime: nil,
      error: nil,
      infectParentStepsWithError: false,
      annotations: [],
      # `attachmentIndices`: the attachments themselves (there is no `testInfo.attachments`).
      attachments: []
    })

    # if (!step.group) this._callbacks.onStepBegin(...)  -- not ported: reporters

    if step.group != "internal" do
      TestTracing.append_before_action_for_step(step._tracing, %{
        stepId: step_id,
        parentId: parent_step && parent_step.stepId,
        title: step.title,
        subtitle: step[:subtitle],
        category: step.category,
        params: step[:params],
        stack: step.stack,
        group: step.group
      })
    end

    step
  end

  # deviation: `.slice(1)` drops the step's own frame only when it is on the stack: BEAM drops
  # a frame that tail-calls. It is when the first frame is at the step's call (`callSite`).
  defp slice_call_site([{module, _fun, _arity, location} | rest] = frames, %{file: file, line: line}) do
    frame_file = to_string(location[:file])
    files = [ClientStackTrace.source_file(module, frame_file), Path.expand(frame_file)]
    if location[:line] == line and Path.expand(file) in files, do: rest, else: frames
  end

  defp slice_call_site(frames, _call_site), do: frames

  defp step_key(step), do: {:test_info, step.testInfo.test_pid, {:step, step.stepId}}

  defp step_row(step) do
    case :ets.lookup(Results.table(), step_key(step)) do
      [{_key, row}] -> row
      [] -> nil
    end
  end

  @doc """
  The step's `complete(result)`: `result` may have `error` (`{kind, reason, stacktrace}`) and
  `softError`, added to the test's errors: a soft matcher's `{kind, reason, stacktrace}`, or an
  exception (a snapshot matcher's), with the caller's stacktrace (upstream's step stack).
  """
  def step_complete(step, result) do
    this = step.testInfo

    row = step_row(step)

    # Elixir only: the test ended, its rows are gone. Its soft error is printed (see
    # `_fail_with_error/2`).
    if row == nil and result[:softError],
      do: _fail_with_error(this, soft_error(result.softError))

    with %{endWallTime: nil} = row <- row do
      row = %{row | endWallTime: System.os_time(:millisecond)}
      # if (result.attachments) ...  -- not ported: no matcher attaches

      row =
        if error = result[:error] do
          # `result.error[stepSymbol] = step`  -- see the deviation in `PlaywrightEx.Test._step/4`
          error = test_info_error(error)

          # `${error.message}`: "undefined" for an exit or throw (a `value`).
          error =
            if step.boxedStack,
              do:
                Map.put(
                  error,
                  :stack,
                  Enum.join(
                    [error[:message] || "undefined" | stringify_stack_frames(stack_frames(step.boxedStack))],
                    "\n"
                  )
                ),
              else: error

          %{row | error: error}
        else
          row
        end

      row =
        if result[:softError] do
          _fail_with_error(this, soft_error(result.softError))
          # Elixir only: a step completes with an infected child only after one of these.
          put_row(this, {:test_info, this.test_pid, :soft_errors}, true)
          %{row | infectParentStepsWithError: true}
        else
          row
        end

      # if (result.shouldNotRetryTest) ...  -- not ported: retries

      # Soft errors inside try/catch will make the test fail.
      # In order to locate the failing step, we are marking all the parent
      # steps as failing unconditionally.
      row =
        if !row.error and :ets.member(Results.table(), {:test_info, this.test_pid, :soft_errors}) do
          child_step =
            Enum.find(child_steps(step), fn child_step -> child_step.error && child_step.infectParentStepsWithError end)

          if child_step, do: %{row | error: child_step.error, infectParentStepsWithError: true}, else: row
        else
          row
        end

      put_row(this, step_key(step), row)

      # if (!step.group) this._callbacks.onStepEnd(...)  -- not ported: reporters

      if step.group != "internal" and step._tracing do
        error_for_trace = if row.error, do: %{name: "", message: row.error[:message] || "", stack: row.error[:stack]}

        TestTracing.append_after_action_for_step(
          step._tracing,
          step.stepId,
          error_for_trace,
          row.attachments,
          row.annotations
        )
      end
    end

    :ok
  end

  # `step.steps`, in the order they were added.
  defp child_steps(step) do
    Results.table()
    |> :ets.match_object({{:test_info, step.testInfo.test_pid, {:step, :_}}, :_})
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1.parentStepId == step.stepId))
    |> Enum.sort_by(& &1.seq)
  end

  @doc """
  `TestStepInfoImpl._runStepBody`: `nil` for a skipped step (an annotation), else the body's
  value. The body takes no step (no `TestStepInfo`, so no `step.skip()` or `step.attach()`).
  """
  def _run_step_body(step, skip, body, location) do
    if skip do
      with %{} = row <- step_row(step),
           do:
             put_row(
               step.testInfo,
               step_key(step),
               %{row | annotations: row.annotations ++ [%{type: "skip", location: location}]}
             )

      nil
    else
      body.()
    end
  end

  defp soft_error({_kind, _reason, _stacktrace} = error), do: error
  defp soft_error(exception), do: {:error, exception, caller_stacktrace()}

  # The frames from the first one outside this application (the test's matcher call).
  defp caller_stacktrace do
    {:current_stacktrace, [_process_info | stacktrace]} = Process.info(self(), :current_stacktrace)

    Enum.drop_while(stacktrace, fn {module, _fun, _arity, _location} ->
      :application.get_application(module) == {:ok, :playwright_ex}
    end)
  end

  # The library, ExUnit, and OTP's and Elixir's own apps (`ClientStackTrace`'s internal ones).
  @runner_apps [{:ok, :playwright_ex}, {:ok, :ex_unit}, {:ok, :elixir}, {:ok, :stdlib}, {:ok, :kernel}]

  @doc "utils `captureRawStack`: the caller's stacktrace (from its caller's frame)."
  def capture_raw_stack do
    {:current_stacktrace, [_process_info, _capture_raw_stack | stacktrace]} = Process.info(self(), :current_stacktrace)
    stacktrace
  end

  @doc """
  utils `filteredStackTrace`, on an Elixir stacktrace: without the frames of the library, of
  ExUnit, of OTP (the runner's `:timer.tc/2`) and of Elixir (`Enum`, `Task`), as upstream drops
  its own packages, the runner's too and Node's internals, or without a file.
  """
  def filtered_stack_trace(stacktrace) do
    Enum.filter(stacktrace, fn
      {module, _fun, _arity, location} when is_atom(module) ->
        location[:file] != nil and :application.get_application(module) not in @runner_apps

      _ ->
        false
    end)
  end

  @doc "An Elixir stacktrace as trace `StackFrame`s (absolute files, as the client's)."
  def stack_frames(stacktrace) do
    for {module, function, arity, location} <- stacktrace, location[:file] != nil do
      %{
        file: ClientStackTrace.source_file(module, to_string(location[:file])),
        line: location[:line] || 0,
        column: 0,
        function: Exception.format_mfa(module, function, arity)
      }
    end
  end

  # utils `stringifyStackFrames`.
  defp stringify_stack_frames(frames) do
    for frame <- frames do
      if frame[:function],
        do: "    at #{frame.function} (#{frame.file}:#{frame.line}:#{frame.column})",
        else: "    at #{frame.file}:#{frame.line}:#{frame.column}"
    end
  end

  @doc """
  worker/util.ts `testInfoError` (`serializeError`, `filterStackTrace`) of `{kind, reason,
  stacktrace}`: `message` and `stack` (`name: message` and the filtered frames) and `cause`
  for an error, `value` for an exit or throw.
  """
  def test_info_error({:error, reason, stacktrace} = error) do
    exception = Exception.normalize(:error, reason, stacktrace)
    message = ErrorContext.error(error).message
    stack_lines = stringify_stack_frames(stack_frames(filtered_stack_trace(stacktrace)))
    cause = Map.get(exception, :cause)

    %{
      message: message,
      stack: Enum.join([message | stack_lines], "\n"),
      cause: if(is_exception(cause), do: test_info_error({:error, cause, []}))
    }
  end

  def test_info_error({kind, reason, stacktrace}), do: %{value: Exception.format_banner(kind, reason, stacktrace)}

  @doc """
  The worker's `_failWithError` of the errors (`{kind, reason, stacktrace}`) the body of the test
  `test_pid` raised: their trace events (ExUnit reports them).
  """
  def trace_errors(test_pid, errors) do
    tracing = Recorder.lookup(test_pid)
    for error <- errors, do: TestTracing.append_for_error(tracing, error)
    :ok
  end

  @doc """
  `_failWithError`: adds `error` (`{kind, reason, stacktrace}`) to the test's errors. The status
  is not kept: the test fails with its errors at the end of its body. Elixir only: once the test
  ended (a process of it outlived its body), the error is printed, as outside a test.
  """
  def _fail_with_error(this, error) do
    key = {:test_info, this.test_pid, {:error, System.unique_integer([:monotonic])}}

    # Taken back if the test ended meanwhile, unless its end took it already (one `take` wins).
    recorded? =
      running?(this) and :ets.insert(Results.table(), {key, error}) and
        (running?(this) or :ets.take(Results.table(), key) == [])

    if recorded?, do: TestTracing.append_for_error(_tracing(this), error), else: IO.puts(error_message(error))
    :ok
  end

  @doc "Elixir only: the `message` of an error `{kind, reason, stacktrace}`."
  def error_message({:error, reason, stacktrace}),
    do: Exception.message(Exception.normalize(:error, reason, stacktrace))

  def error_message({kind, reason, stacktrace}), do: Exception.format_banner(kind, reason, stacktrace)

  @doc """
  `_deadline()`: `%{deadline: _, timeout: _}`, the test's deadline (monotonic milliseconds) and
  timeout. Without a test timeout the deadline is `:infinity` (upstream's `kMaxDeadline`).
  """
  def _deadline(this) do
    # deviation: `:infinity` for `kMaxDeadline`, as BEAM's monotonic clock may be any integer. And
    # the deadline is when the recorder closes the test's contexts, just before ExUnit kills the
    # test (`Recorder.test_timeout_margin/1`), where upstream's timeout fails the test: so a
    # matcher (`toPass`) ends before that, with its own error.
    case this[:deadline] do
      nil -> %{deadline: :infinity, timeout: this[:test_timeout]}
      deadline -> %{deadline: deadline - Recorder.test_timeout_margin(this.test_timeout), timeout: this.test_timeout}
    end
  end

  @doc """
  `attach`: the attachment `name` of `options` (`path`, `body`, `contentType`), a `test.attach`
  step whose `after` event carries it into the trace.
  """
  def attach(this, name, options) do
    step = _add_step(this, %{title: "Attach #{StringUtils.escape_with_quotes(name, "\"")}", category: "test.attach"})
    _attach(this, normalize_and_save_attachment(output_path(this), name, options), step)
    step_complete(step, %{})
  end

  # `_attach(attachment, stepId)`, with the step itself. `_attachmentsPush`, `onAttach`  -- not
  # ported: reporters
  defp _attach(this, attachment, step) do
    step = if step[:group], do: nil, else: step

    with %{} = step <- step,
         %{} = row <- step_row(step) do
      put_row(this, step_key(step), %{row | attachments: row.attachments ++ [attachment]})
    else
      _ ->
        step_id = "#{this.step_id_prefix}@#{System.unique_integer([:positive, :monotonic])}"
        title = "Attach #{StringUtils.escape_with_quotes(attachment.name, "\"")}"
        tracing = _tracing(this)

        TestTracing.append_before_action_for_step(tracing, %{
          stepId: step_id,
          title: title,
          category: "test.attach",
          stack: []
        })

        TestTracing.append_after_action_for_step(tracing, step_id, nil, [attachment])
    end
  end

  # util.ts `normalizeAndSaveAttachment`. deviation: a binary `body` is text unless it is not
  # UTF-8 (JS tells a string from a Buffer).
  defp normalize_and_save_attachment(output_path, name, options) do
    case options do
      %{path: nil, body: nil} ->
        %{name: name, contentType: "text/plain"}

      %{path: path, body: nil} ->
        hash = calculate_sha1(path)
        sanitized_name_prefix = sanitize_for_file_path(name) <> "-"
        dest = Path.join([output_path, "attachments", sanitized_name_prefix <> hash <> Path.extname(path)])
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(path, dest)

        content_type =
          options.contentType || MimeType.get_mime_type_for_path(Path.basename(path)) || "application/octet-stream"

        %{name: name, contentType: content_type, path: dest}

      %{path: nil, body: body} ->
        content_type =
          options.contentType || if(String.valid?(body), do: "text/plain", else: "application/octet-stream")

        %{name: name, contentType: content_type, body: body}

      _ ->
        raise ~s(Exactly one of "path" and "body" must be specified)
    end
  end

  # `outputPath()`: the output dir, created.
  defp output_path(this) do
    File.mkdir_p!(this.output_dir)
    this.output_dir
  end

  @doc "`_getOutputPath`: the path of `path_segments` in the test's output dir, which it must stay in."
  def _get_output_path(this, path_segments) do
    joined_path = Path.join(path_segments)

    case get_contained_path(this.output_dir, joined_path) do
      nil ->
        raise "The outputPath is not allowed outside of the parent directory. Please fix the defined path.\n\n\toutputPath: #{joined_path}"

      output_path ->
        output_path
    end
  end

  # util.ts `getContainedPath`.
  defp get_contained_path(parent_path, sub_path) do
    resolved_path = Path.expand(sub_path, parent_path)
    if resolved_path == parent_path or String.starts_with?(resolved_path, parent_path <> "/"), do: resolved_path
  end

  @doc "`_fsSanitizedTestName`."
  def _fs_sanitized_test_name(this), do: sanitize_for_file_path(trim_long_string(this.test_name))

  @doc """
  `_resolveSnapshotPaths`: `%{absoluteSnapshotPath: _, relativeOutputPath: _}` of the snapshot
  `name` (a string, a list of path segments, or `nil` for the test's next anonymous one) of
  `kind` (`"snapshot"`, `"screenshot"` or `"aria"`).
  """
  def _resolve_snapshot_paths(this, kind, name, update_snapshot_index, anonymous_extension \\ nil) do
    # NOTE: snapshot path must not ever change for backwards compatibility!

    snapshot_names = if kind == "aria", do: :_ariaSnapshotNames, else: :_snapshotNames
    expect = Expect.expect_config()

    {sub_path, ext, relative_output_path} =
      if name in [nil, ""] do
        default_extensions = %{
          "aria" => ".aria.yml",
          "screenshot" => "." <> (expect[:toHaveScreenshot][:type] || "png"),
          "snapshot" => ".txt"
        }

        index = next_index(this, {snapshot_names, :lastAnonymousSnapshotIndex}, update_snapshot_index)
        anonymous_paths(this, index, anonymous_extension || default_extensions[kind])
      else
        {sub_path, ext, relative_output_path} = named_paths(kind, name)
        index = next_index(this, {snapshot_names, :lastNamedSnapshotIndex, relative_output_path}, update_snapshot_index)

        relative_output_path =
          if index > 1,
            do: PlaywrightEx.Matchers.ToMatchSnapshot.add_suffix_to_file_path(relative_output_path, "-#{index - 1}"),
            else: relative_output_path

        {sub_path, ext, relative_output_path}
      end

    name_argument = path_join(Path.dirname(sub_path), Path.basename(sub_path, ext))
    absolute_snapshot_path = _apply_path_template(this, template(kind, expect), name_argument, ext)
    %{absoluteSnapshotPath: absolute_snapshot_path, relativeOutputPath: relative_output_path}
  end

  # Consider the use case below. We should save actual to different paths, so we use |nextAnonymousSnapshotIndex|.
  #
  #   expect.toMatchSnapshot('a.png')
  #   // noop
  #   expect.toMatchSnapshot('a.png')
  defp anonymous_paths(this, index, ext) do
    full_title_without_spec = Enum.join([this.test_name, index], " ")
    sub_path = sanitize_file_path_before_extension(trim_long_string(full_title_without_spec) <> ext, ext)
    # Trim the output file paths more aggressively to avoid hitting Windows filesystem limits.
    relative_output_path =
      sanitize_file_path_before_extension(trim_long_string(full_title_without_spec, 60) <> ext, ext)

    {sub_path, ext, relative_output_path}
  end

  # We intentionally do not sanitize user-provided array of segments,
  # assuming it is a file system path.
  # See https://github.com/microsoft/playwright/pull/9156.
  defp named_paths(kind, name) when is_list(name) do
    sub_path = Path.join(name)
    {sub_path, aria_aware_extname(kind, sub_path), Path.join(name)}
  end

  defp named_paths(kind, name) do
    ext = aria_aware_extname(kind, name)
    # Trim the output file paths more aggressively to avoid hitting Windows filesystem limits.
    {sanitize_file_path_before_extension(name, ext), ext,
     sanitize_file_path_before_extension(trim_long_string(name, 60), ext)}
  end

  defp aria_aware_extname("aria", file_path) do
    if String.ends_with?(file_path, ".aria.yml"), do: ".aria.yml", else: Path.extname(file_path)
  end

  defp aria_aware_extname(_kind, file_path), do: Path.extname(file_path)

  @legacy_template "{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{-projectName}{-snapshotSuffix}{ext}"
  @aria_default_template "{snapshotDir}/{testFileDir}/{testFileName}-snapshots/{arg}{ext}"

  defp template(kind, expect) do
    snapshot_path_template = presence(PlaywrightEx.Test.Options.snapshot_path_template())

    case kind do
      "screenshot" ->
        presence(expect[:toHaveScreenshot][:pathTemplate]) || snapshot_path_template || @legacy_template

      "aria" ->
        presence(expect[:toMatchAriaSnapshot][:pathTemplate]) || snapshot_path_template || @aria_default_template

      _ ->
        snapshot_path_template || @legacy_template
    end
  end

  # `lastAnonymousSnapshotIndex` / `lastNamedSnapshotIndex[relativeOutputPath]` plus one, stored
  # with `"updateSnapshotIndex"`. A counter row: atomic across the test's processes.
  defp next_index(this, name, "updateSnapshotIndex") do
    key = {:test_info, this.test_pid, name}
    index = :ets.update_counter(Results.table(), key, {2, 1}, {key, 0})
    # Elixir only: the test ended (see `put_row/3`).
    if !running?(this), do: :ets.delete(Results.table(), key)
    index
  end

  defp next_index(this, name, "dontUpdateSnapshotIndex") do
    case :ets.lookup(Results.table(), {:test_info, this.test_pid, name}) do
      [{_key, index}] -> index + 1
      [] -> 1
    end
  end

  @doc "`_applyPathTemplate`. There are no projects: `{projectName}` is empty, as upstream's default project's."
  def _apply_path_template(this, template, name_argument, ext) do
    # `path.relative(testDir, file)`: `../integration/...` for a file of another `test_paths` dir.
    relative_test_file_path = Path.relative_to(this.file, test_dir(), force: true)
    parsed_dir = if Path.dirname(relative_test_file_path) == ".", do: "", else: Path.dirname(relative_test_file_path)
    parsed_base = Path.basename(relative_test_file_path)
    parsed_name = Path.rootname(parsed_base)
    project_name_path_segment = sanitize_for_file_path("")
    snapshot_suffix = snapshot_suffix()
    snapshot_dir = Path.expand(PlaywrightEx.Test.Options.snapshot_dir() || test_dir())

    snapshot_path =
      template
      |> replace("testDir", test_dir())
      |> replace("snapshotDir", snapshot_dir)
      |> replace("snapshotSuffix", snapshot_suffix, snapshot_suffix != "")
      |> replace("testFileDir", parsed_dir)
      |> replace("platform", platform())
      |> replace("projectName", project_name_path_segment, project_name_path_segment != "")
      |> replace("testName", _fs_sanitized_test_name(this))
      |> replace("testFileBaseName", parsed_name)
      |> replace("testFileName", parsed_base)
      |> replace("testFilePath", relative_test_file_path)
      |> replace("arg", name_argument)
      |> replace("ext", ext, ext != "")

    Path.expand(snapshot_path, File.cwd!())
  end

  # `.replace(/\{(.)?token\}/g, '$1' + value)`, or `''` when `present?` is false.
  defp replace(template, token, value, present? \\ true) do
    Regex.replace(~r/\{(.)?#{token}\}/, template, fn _match, separator ->
      if present?, do: separator <> value, else: ""
    end)
  end

  @doc """
  `snapshotPath`: the snapshot path of `name` (a string, or a list of path segments) of `kind`
  (`"snapshot"`, `"screenshot"` or `"aria"`), without counting it as used.
  """
  def snapshot_path(this, name, kind \\ "snapshot") do
    if kind not in ["snapshot", "screenshot", "aria"],
      do:
        raise(
          ArgumentError,
          ~s(testInfo.snapshotPath: unknown kind "#{kind}", must be one of "snapshot", "screenshot" or "aria")
        )

    # Assume a zero/single path segment corresponds to `toHaveScreenshot(name)`,
    # while multiple path segments correspond to `toHaveScreenshot([...name])`.
    name =
      case List.wrap(name) do
        [] -> nil
        [segment] -> segment
        segments -> segments
      end

    _resolve_snapshot_paths(this, kind, name, "dontUpdateSnapshotIndex").absoluteSnapshotPath
  end

  # `testInfo.snapshotSuffix = process.platform` (the auto fixture `_setupContextOptions`).
  defp snapshot_suffix, do: platform()

  @doc "Node's `process.platform`."
  def platform do
    case :os.type() do
      {:win32, _} -> "win32"
      {_family, name} -> Atom.to_string(name)
    end
  end

  # util.ts `sanitizeFilePathBeforeExtension`.
  defp sanitize_file_path_before_extension(file_path, ext) do
    base = String.slice(file_path, 0, String.length(file_path) - String.length(ext))
    sanitize_for_file_path(base) <> ext
  end

  # Node's `path.join` of a dir and a name: no `./` for the current dir.
  defp path_join(".", name), do: name
  defp path_join(dir, name), do: Path.join(dir, name)

  # JS `||` on strings: `''` is falsy.
  defp presence(""), do: nil
  defp presence(value), do: value
end
