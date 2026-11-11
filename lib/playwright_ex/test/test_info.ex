defmodule PlaywrightEx.Test.TestInfo do
  @moduledoc false
  # What the ported matchers need of upstream's `TestInfoImpl`
  # (`packages/playwright/src/worker/testInfo.ts`) for a test of `use PlaywrightEx.Test`: its
  # snapshot paths (`_resolveSnapshotPaths`, `snapshotPath`), output paths (`_getOutputPath`) and
  # error list (`_failWithError`), which fails the test when its body ends
  # (`PlaywrightEx.Test.__passed__/0`).
  #
  # `this` is a map of the test's static fields. Its mutable state, the snapshot indexes and the
  # errors, are rows of the pool's public table keyed `{:test_info, test_pid, _}`, as a matcher
  # may run in another process of the test (`$callers`). The pool deletes them when the test's
  # process ends.

  alias PlaywrightEx.Matchers.Expect
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder

  @doc "The test's fields: `test_pid`, `file`, `test_name` (`titlePath.slice(1).join(' ')`), `output_dir`."
  def new(context) do
    %{
      test_pid: context.test_pid,
      file: Path.expand(context.file),
      test_name: Recorder.test_name(context),
      output_dir: Path.expand(Recorder.output_dir(context))
    }
  end

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

  @doc "Takes the errors `_fail_with_error/2` recorded for the test `test_pid`."
  def take_errors(test_pid) do
    rows = :ets.match_object(Pool.table(), {{:test_info, test_pid, {:error, :_}}, :_})
    for {key, _error} <- rows, do: :ets.delete(Pool.table(), key)
    rows |> Enum.sort_by(fn {{_, _, {:error, seq}}, _error} -> seq end) |> Enum.map(&elem(&1, 1))
  end

  @doc """
  The part of a step's `complete` (`_addStep`) that needs no steps: a result's `softError` is
  added to the test's errors, with the caller's stacktrace (upstream's step stack).
  """
  # The rest of `complete` (attachments, the step's error) waits for steps; `shouldNotRetryTest`
  # needs retries, which ExUnit has none of.
  def step_complete(this, result) do
    if result[:softError], do: _fail_with_error(this, {:error, result.softError, caller_stacktrace()})
    :ok
  end

  # The frames from the first one outside this application (the test's matcher call).
  defp caller_stacktrace do
    {:current_stacktrace, [_process_info | stacktrace]} = Process.info(self(), :current_stacktrace)

    Enum.drop_while(stacktrace, fn {module, _fun, _arity, _location} ->
      :application.get_application(module) == {:ok, :playwright_ex}
    end)
  end

  @doc """
  `_failWithError`: adds `error` (`{kind, reason, stacktrace}`) to the test's errors. The status
  is not kept: the test fails with its errors at the end of its body.
  """
  def _fail_with_error(this, error) do
    # Not in the trace: `PlaywrightEx.Test` records no test steps or errors in it.
    :ets.insert(Pool.table(), {{:test_info, this.test_pid, {:error, System.unique_integer([:monotonic])}}, error})
    :ok
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
    :ets.update_counter(Pool.table(), key, {2, 1}, {key, 0})
  end

  defp next_index(this, name, "dontUpdateSnapshotIndex") do
    case :ets.lookup(Pool.table(), {:test_info, this.test_pid, name}) do
      [{_key, index}] -> index + 1
      [] -> 1
    end
  end

  @doc "`_applyPathTemplate`. There are no projects: `{projectName}` is empty, as upstream's default project's."
  def _apply_path_template(this, template, name_argument, ext) do
    relative_test_file_path = Recorder.relative_test_file(this.file)
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

  # Node's `process.platform`.
  defp platform do
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
