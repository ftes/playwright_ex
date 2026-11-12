defmodule PlaywrightEx.Test.TestInfo do
  @moduledoc false
  # What the ported matchers need of upstream's `TestInfoImpl`
  # (`packages/playwright/src/worker/testInfo.ts`) for a test of `use PlaywrightEx.Test`: its
  # snapshot paths (`_resolveSnapshotPaths`, `snapshotPath`), output paths (`_getOutputPath`) and
  # error list (`_failWithError`), which fails the test when its body ends
  # (`PlaywrightEx.Test.__passed__/0`), and its steps (`_addStep`), traced by its `_tracing`
  # (`PlaywrightEx.Test.TestTracing`).
  #
  # `this` is a map of the test's static fields. Its mutable state, the snapshot indexes, the
  # errors and the steps, are rows of the pool's public table keyed `{:test_info, test_pid, _}`,
  # as a matcher or step may run in another process of the test (`$callers`). The pool deletes
  # them when the test's process ends, and fails the test with the errors left.

  alias PlaywrightEx.Client.ClientStackTrace
  alias PlaywrightEx.Matchers.Expect
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.Test.ErrorContext
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.TestTracing

  @doc "The test's fields: `test_pid`, `file`, `test_name` (`titlePath.slice(1).join(' ')`), `output_dir`."
  def new(context) do
    %{
      test_pid: context.test_pid,
      file: Path.expand(context.file),
      test_name: Recorder.test_name(context),
      output_dir: Path.expand(Recorder.output_dir(context)),
      # `nextStepId = createCallIdGenerator()`: its prefix.
      step_id_prefix: for(_ <- 1..4, into: "", do: <<Enum.random(?a..?z)>>)
    }
  end

  # `_tracing`: the test's recorder, if it records artifacts.
  defp _tracing(this), do: Recorder.lookup(this.test_pid)

  @doc "Registers the running test of `context` (in its `setup`): matchers of its processes find it."
  def start(context) do
    this = new(context)
    :ets.insert(Pool.table(), {{:test_info, this.test_pid, :info}, this})
    :ok
  end

  @doc """
  Upstream's `expectConfig().testInfo`: the running test of this process, or of a process in its
  `$callers` (a `Task` of the test), else `nil`.
  """
  def current do
    if Pool.started?(), do: Enum.find_value([self() | List.wrap(Process.get(:"$callers"))], &lookup/1)
  end

  defp lookup(pid) do
    case :ets.lookup(Pool.table(), {:test_info, pid, :info}) do
      [{_key, this}] -> this
      [] -> nil
    end
  end

  @doc """
  The end of the test's body: unregisters it (later matchers run as outside a test) and returns
  its errors (`{kind, reason, stacktrace}`), in the order they were recorded.
  """
  def finish(test_pid) do
    if Pool.started?() do
      :ets.delete(Pool.table(), {:test_info, test_pid, :info})
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
    :ets.select_delete(Pool.table(), [{{{:test_info, test_pid, :"$1"}, :_}, [not_error], [true]}])
    errors
  end

  @doc "Takes the errors `_fail_with_error/2` recorded for the test `test_pid`."
  def take_errors(test_pid) do
    # One by one (`take`): a row `_fail_with_error/2` took back is not counted.
    Pool.table()
    |> :ets.match_object({{:test_info, test_pid, {:error, :_}}, :_})
    |> Enum.flat_map(fn {key, _error} -> :ets.take(Pool.table(), key) end)
    |> Enum.sort_by(fn {{_, _, {:error, seq}}, _error} -> seq end)
    |> Enum.map(&elem(&1, 1))
  end

  # Whether the test runs: the end of its body, and the pool, unregister it before taking its
  # errors and rows.
  defp running?(this), do: lookup(this.test_pid) != nil

  # Elixir only: a row of the test. One written once the test ended (by a process of the test
  # that outlived its body) is removed again, as the pool may have removed its rows.
  defp put_row(this, key, value) do
    :ets.insert(Pool.table(), {key, value})
    if !running?(this), do: :ets.delete(Pool.table(), key)
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
        # Elixir only: the recorder its `before` went to, which its `after` goes to. The test
        # may start recording inside the step (`PlaywrightEx.Test.new_context/2`), and an `after`
        # without its `before` breaks the trace viewer.
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
      annotations: []
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
    case :ets.lookup(Pool.table(), step_key(step)) do
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
      # if (result.attachments) ...  -- not ported: attachments

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
        if !row.error and :ets.member(Pool.table(), {:test_info, this.test_pid, :soft_errors}) do
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
        TestTracing.append_after_action_for_step(step._tracing, step.stepId, error_for_trace, [], row.annotations)
      end
    end

    :ok
  end

  # `step.steps`, in the order they were added.
  defp child_steps(step) do
    Pool.table()
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

  @runner_apps [{:ok, :playwright_ex}, {:ok, :ex_unit}, {:ok, :stdlib}, {:ok, :kernel}]

  @doc "utils `captureRawStack`: the caller's stacktrace (from its caller's frame)."
  def capture_raw_stack do
    {:current_stacktrace, [_process_info, _capture_raw_stack | stacktrace]} = Process.info(self(), :current_stacktrace)
    stacktrace
  end

  @doc """
  utils `filteredStackTrace`, on an Elixir stacktrace: without the frames of the library, of
  ExUnit and of OTP (the runner's `:timer.tc/2`), as upstream drops its own packages, the
  runner's too, or without a file.
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
      running?(this) and :ets.insert(Pool.table(), {key, error}) and
        (running?(this) or :ets.take(Pool.table(), key) == [])

    if recorded?, do: TestTracing.append_for_error(_tracing(this), error), else: IO.puts(error_message(error))
    :ok
  end

  defp error_message({:error, reason, stacktrace}),
    do: Exception.message(Exception.normalize(:error, reason, stacktrace))

  defp error_message({kind, reason, stacktrace}), do: Exception.format_banner(kind, reason, stacktrace)

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
  def _fs_sanitized_test_name(this), do: Recorder.sanitize_for_file_path(Recorder.trim_long_string(this.test_name))

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
    sub_path = sanitize_file_path_before_extension(Recorder.trim_long_string(full_title_without_spec) <> ext, ext)
    # Trim the output file paths more aggressively to avoid hitting Windows filesystem limits.
    relative_output_path =
      sanitize_file_path_before_extension(Recorder.trim_long_string(full_title_without_spec, 60) <> ext, ext)

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
     sanitize_file_path_before_extension(Recorder.trim_long_string(name, 60), ext)}
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
    index = :ets.update_counter(Pool.table(), key, {2, 1}, {key, 0})
    # Elixir only: the test ended (see `put_row/3`).
    if !running?(this), do: :ets.delete(Pool.table(), key)
    index
  end

  defp next_index(this, name, "dontUpdateSnapshotIndex") do
    case :ets.lookup(Pool.table(), {:test_info, this.test_pid, name}) do
      [{_key, index}] -> index + 1
      [] -> 1
    end
  end

  @doc "`_applyPathTemplate`. There are no projects: `{projectName}` is empty, as upstream's default project's."
  def _apply_path_template(this, template, name_argument, ext) do
    # `path.relative(testDir, file)`: `../integration/...` for a file of another `test_paths` dir.
    relative_test_file_path = Path.relative_to(this.file, Recorder.test_dir(), force: true)
    parsed_dir = if Path.dirname(relative_test_file_path) == ".", do: "", else: Path.dirname(relative_test_file_path)
    parsed_base = Path.basename(relative_test_file_path)
    parsed_name = Path.rootname(parsed_base)
    project_name_path_segment = Recorder.sanitize_for_file_path("")
    snapshot_suffix = snapshot_suffix()
    snapshot_dir = Path.expand(PlaywrightEx.Test.Options.snapshot_dir() || Recorder.test_dir())

    snapshot_path =
      template
      |> replace("testDir", Recorder.test_dir())
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
    Recorder.sanitize_for_file_path(base) <> ext
  end

  # Node's `path.join` of a dir and a name: no `./` for the current dir.
  defp path_join(".", name), do: name
  defp path_join(dir, name), do: Path.join(dir, name)

  # JS `||` on strings: `''` is falsy.
  defp presence(""), do: nil
  defp presence(value), do: value
end
