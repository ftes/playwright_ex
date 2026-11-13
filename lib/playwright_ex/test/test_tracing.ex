defmodule PlaywrightEx.Test.TestTracing do
  @moduledoc false
  # Upstream's `TestTracing` (`packages/playwright/src/worker/testTracing.ts`): the test's own
  # events, its steps and errors, as the `test.trace` entry of its `trace.zip`.
  #
  # `this` is a map in the state of the test's recorder (`PlaywrightEx.Test.Recorder`), which
  # holds the rest of the class: the trace mode (`_options`) and the context chunks
  # (`_temporaryTraceFiles`). The `append_*` functions build an event in the calling process (a
  # step's, its time) and add it through the recorder, the test's `_tracing`, `nil` without one
  # (a test with the trace `off` starts its recorder on its first context: upstream drops the
  # events with the mode `off`).

  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.TestInfo

  @test_trace_entry_name "test.trace"
  @version 10

  # traceOrdinal, generateNextTraceRecordingName, traceTitle, traceOptions  -- ported as the
  # name and title of `Recorder`'s chunks (`start_tracing/2`)
  # _liveTraceFile  -- not ported: live tracing (UI mode)

  @doc "The constructor: `this` with the `context-options` event of the test runner."
  def new do
    context_created_event = %{
      version: @version,
      type: "context-options",
      origin: "testRunner",
      browserName: "",
      playwrightVersion: PlaywrightEx.Driver.version(),
      options: %{},
      platform: TestInfo.platform(),
      wallTime: System.os_time(:millisecond),
      monotonicTime: monotonic_time(),
      sdkLanguage: "javascript"
    }

    # Newest first.
    %{trace_events: [context_created_event], did_finish_test_function_and_after_each_hooks: false, failed: nil}
  end

  @doc """
  `startIfNeeded`, at the test's registration: its trace options, with mode `:off` (upstream's
  `this._options = undefined`) unless `_shouldCaptureTrace` for its `retry`. A test without
  the recorder has no trace.
  """
  def start_if_needed([{:mode, mode} | options] = trace, retry) do
    if should_capture_trace(mode, retry), do: trace, else: [{:mode, :off} | options]
  end

  # `_shouldCaptureTrace`.
  defp should_capture_trace(mode, retry) do
    cond do
      mode == :on -> true
      mode == :retain_on_failure -> true
      mode == :on_first_retry and retry == 1 -> true
      mode == :on_all_retries and retry > 0 -> true
      mode == :retain_on_first_failure and retry == 0 -> true
      mode == :retain_on_failure_and_retries -> true
      true -> false
    end
  end

  @doc """
  `didFinishTestFunctionAndAfterEachHooks`, in the recorder's `finish`: after the test's other
  `on_exit` callbacks (upstream's `afterEach` hooks), before it closes the contexts left. With
  the test's result, which `_shouldAbandonTrace` reads (upstream's `testInfo.status`).
  """
  def did_finish_test_function_and_after_each_hooks(this, failed?),
    do: %{this | did_finish_test_function_and_after_each_hooks: true, failed: failed?}

  defp generate_next_trace_recording_path(tmp) do
    File.mkdir_p!(tmp)
    Path.join(tmp, "#{System.unique_integer([:positive])}.zip")
  end

  @doc """
  `maybeGenerateNextTraceRecordingPath`, with the trace `mode` and the test's `retry`: the path
  of a context's chunk under `tmp`, or `nil` for `Tracing.stopChunk` to discard it.
  """
  def maybe_generate_next_trace_recording_path(this, mode, retry, tmp) do
    # Forget about traces that should be saved on failure, when no failure happened
    # during the test and beforeEach/afterEach hooks.
    # This avoids downloading traces over the wire when not really needed.
    if this.did_finish_test_function_and_after_each_hooks and should_abandon_trace(mode, this.failed, retry),
      do: nil,
      else: generate_next_trace_recording_path(tmp)
  end

  # `_shouldAbandonTrace` (mode `:off` is upstream's `!this._options`, which `stopIfNeeded`
  # returns on before).
  defp should_abandon_trace(:retain_on_failure_and_retries, failed?, retry), do: !failed? and retry == 0

  defp should_abandon_trace(mode, failed?, _retry),
    do: !failed? and mode in [:retain_on_failure, :retain_on_first_failure]

  @doc """
  `stopIfNeeded`, in the recorder's `finish`: with the test's registration `test` (its `trace`
  options, `mode` first, `test_timeout`, `tmp` and `output_dir`) and result, adds `test.trace`
  (with the sources of its steps) to the context `chunks` and merges them into the output dir's
  `trace.zip`, its path returned, or drops the chunks (`nil`).
  """
  def stop_if_needed(this, %{trace: [{:mode, mode} | options]} = test, chunks, failed?) do
    [context_created_event | events] = Enum.reverse(this.trace_events)
    timeout = if is_integer(test[:test_timeout]), do: test.test_timeout, else: 0
    context_created_event = Map.merge(context_created_event, %{testTimeout: timeout, annotations: []})
    trace_events = [context_created_event | events]

    cond do
      mode == :off ->
        nil

      should_abandon_trace(mode, failed?, test.retry) ->
        for file <- chunks, do: File.rm(file)
        nil

      true ->
        trace_events =
          if Keyword.get(options, :attachments, true),
            do: trace_events,
            else: Enum.map(trace_events, &if(&1.type == "after", do: Map.delete(&1, :attachments), else: &1))

        sources =
          if Keyword.get(options, :sources, true) do
            source_files =
              Enum.uniq(for %{type: "before"} = event <- trace_events, frame <- event.stack || [], do: frame.file)

            for source_file <- source_files,
                {:ok, source} <- [File.read(source_file)],
                do: {~c"src/#{TestInfo.calculate_sha1(source_file)}#{Path.extname(source_file)}", source}
          else
            []
          end

        # The `after` events' attachments, each content once, as `attachments/<sha1>`.
        {trace_events, {attachment_files, _sha1s}} =
          Enum.map_reduce(trace_events, {[], MapSet.new()}, fn
            %{type: "after", attachments: [_ | _] = attachments} = event, acc ->
              {attachments, acc} = Enum.map_reduce(attachments, acc, &attachment_file/2)
              {%{event | attachments: attachments}, acc}

            event, acc ->
              {event, acc}
          end)

        trace_content = Enum.map_join(trace_events, "\n", &JSON.encode!(drop_undefined(&1)))
        file = generate_next_trace_recording_path(test.tmp)

        {:ok, _} =
          :zip.create(
            String.to_charlist(file),
            sources ++ Enum.reverse(attachment_files) ++ [{String.to_charlist(@test_trace_entry_name), trace_content}]
          )

        path = Path.join(test.output_dir, "trace.zip")
        merge_trace_files(path, chunks ++ [file])
        # this._testInfo.attachments.push({ name: 'trace', ... });  -- not ported: attachments; the path is returned
        path
    end
  end

  defp attachment_file(attachment, {files, sha1s} = acc) do
    case attachment_content(attachment) do
      nil ->
        {attachment, acc}

      content ->
        sha1 = TestInfo.calculate_sha1(content)
        attachment = attachment |> Map.drop([:path, :base64]) |> Map.put(:file, "attachments/" <> sha1)

        if MapSet.member?(sha1s, sha1),
          do: {attachment, acc},
          else: {attachment, {[{~c"attachments/#{sha1}", content} | files], MapSet.put(sha1s, sha1)}}
    end
  end

  defp attachment_content(%{path: path}) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp attachment_content(%{base64: base64}) when is_binary(base64), do: Base.decode64!(base64)
  defp attachment_content(_attachment), do: nil

  @doc "`appendForError`: `error` is `{kind, reason, stacktrace}`."
  def append_for_error(this, error) do
    # const rawStack = error.stack?.split('\n') || []; const stack = filteredStackTrace(rawStack);
    {_kind, _reason, raw_stack} = error
    stack = TestInfo.stack_frames(TestInfo.filtered_stack_trace(raw_stack))
    _append_trace_event(this, %{type: "error", message: _format_error(TestInfo.test_info_error(error)), stack: stack})
  end

  @doc "`_formatError` of a `testInfoError`."
  def _format_error(error) do
    parts = [error[:message] || to_string(error[:value])]
    parts = if error[:cause], do: parts ++ ["[cause]: " <> _format_error(error.cause)], else: parts
    Enum.join(parts, "\n")
  end

  # appendStdioToTrace  -- not ported: the test's stdout would need a group leader of its own,
  # which processes outliving the test inherit; stderr does not go through the group leader

  @doc "`appendBeforeActionForStep`."
  def append_before_action_for_step(this, options) do
    _append_trace_event(this, %{
      type: "before",
      callId: options.stepId,
      parentId: options[:parentId],
      startTime: monotonic_time(),
      class: "Test",
      method: options.category,
      title: options.title,
      subtitle: options[:subtitle],
      params: Map.new(options[:params] || %{}, fn {name, value} -> {name, generate_preview(value)} end),
      stack: options.stack,
      group: options[:group]
    })
  end

  @doc "`appendAfterActionForStep`."
  def append_after_action_for_step(this, call_id, error \\ nil, attachments \\ [], annotations \\ nil) do
    _append_trace_event(this, %{
      type: "after",
      callId: call_id,
      endTime: monotonic_time(),
      attachments: serialize_attachments(attachments),
      annotations: annotations,
      error: error
    })
  end

  defp _append_trace_event(nil, _event), do: :ok
  defp _append_trace_event(this, event), do: Recorder.append_trace_event(this, event)

  # `serializeAttachments`: attachments are `%{name, contentType, path | body}`.
  defp serialize_attachments([]), do: nil

  defp serialize_attachments(attachments) do
    for a <- attachments, a.name != "trace" do
      %{name: a.name, contentType: a.contentType, path: a[:path], base64: a[:body] && Base.encode64(a.body)}
    end
  end

  @doc """
  `generatePreview`. Elixir values: `nil` is `undefined`, `:null` is `null`, maps and structs
  (a `Regex`) are objects, other atoms their names.
  """
  def generate_preview(value), do: value |> generate_preview(MapSet.new()) |> elem(0)

  defp generate_preview(value, visited) do
    if MapSet.member?(visited, value) do
      {"", visited}
    else
      visited = MapSet.put(visited, value)

      case value do
        value when is_binary(value) ->
          {value, visited}

        value when is_number(value) or is_boolean(value) ->
          {to_string(value), visited}

        :null ->
          {"null", visited}

        nil ->
          {"undefined", visited}

        value when is_list(value) ->
          {previews, visited} = Enum.map_reduce(value, visited, &generate_preview/2)
          {"[" <> Enum.join(previews, ", ") <> "]", visited}

        value when is_map(value) ->
          {"Object", visited}

        value when is_atom(value) ->
          {Atom.to_string(value), visited}

        value ->
          {inspect(value), visited}
      end
    end
  end

  @doc """
  `mergeTraceFiles`: one trace of all of the test's chunks, each cut to its own stacks
  (`own_stacks/2`). With several chunks, newest first, `*trace.<ext>` entries get their chunk's
  index as a prefix, other entries (resources) are kept once. Returns `:none` without chunks.
  """
  def merge_trace_files(path, chunks) do
    case Enum.filter(chunks, &File.exists?/1) do
      [] ->
        :none

      chunks ->
        {entries, _names} =
          chunks
          |> Enum.with_index()
          |> Enum.reverse()
          |> Enum.reduce({[], MapSet.new()}, fn {chunk, i}, acc ->
            Enum.reduce(read_chunk(chunk), acc, &merge_entry(&1, prefix(i, chunks), &2))
          end)

        File.mkdir_p!(Path.dirname(path))
        {:ok, _} = :zip.create(String.to_charlist(path), Enum.reverse(entries))
        Enum.each(chunks, &File.rm/1)
        :ok
    end
  end

  defp prefix(_i, [_chunk]), do: ""
  defp prefix(i, _chunks), do: "#{i}-"

  defp read_chunk(chunk) do
    {:ok, files} = :zip.unzip(String.to_charlist(chunk), [:memory])
    files = Enum.map(files, fn {name, data} -> {to_string(name), data} end)
    own_stacks(files, List.keyfind(files, "trace.stacks", 0))
  end

  # The driver adds every call's stack to every trace recording on its connection
  # (`addStackToTracingNoReply`), also those of other processes' calls. Keeps the stacks of
  # the chunk's own actions (by `callId`), as `serializeClientSideCallMetadata` writes them, and
  # the `src/<sha1(file)><ext>` sources of their frames.
  defp own_stacks(files, nil), do: files

  defp own_stacks(files, {_, data}) do
    ids =
      for {name, trace} <- files,
          Path.extname(name) == ".trace",
          line <- String.split(trace, "\n", trim: true),
          into: MapSet.new(),
          do: JSON.decode!(line)["callId"]

    %{"files" => paths, "stacks" => stacks} = JSON.decode!(data)
    stacks = Enum.filter(stacks, fn [id, _frames] -> id in ids end)
    used = stacks |> Enum.flat_map(fn [_id, frames] -> Enum.map(frames, &hd/1) end) |> Enum.uniq()
    index = used |> Enum.with_index() |> Map.new()
    stacks = for [id, frames] <- stacks, do: [id, for([file | rest] <- frames, do: [index[file] | rest])]
    paths = Enum.map(used, &Enum.at(paths, &1))
    sources = MapSet.new(paths, &"src/#{TestInfo.calculate_sha1(&1)}#{Path.extname(&1)}")
    stacks_data = JSON.encode!(%{files: paths, stacks: stacks})

    for {name, _} = file <- files,
        not String.starts_with?(name, "src/") or name in sources,
        do: if(name == "trace.stacks", do: {name, stacks_data}, else: file)
  end

  defp merge_entry({name, data}, prefix, {entries, names}) do
    name = if name != "test.trace" and name =~ ~r/trace\.[a-z]*$/, do: prefix <> name, else: name

    if MapSet.member?(names, name),
      do: {entries, names},
      else: {[{String.to_charlist(name), data} | entries], MapSet.put(names, name)}
  end

  # JSON.stringify leaves out `undefined` values.
  defp drop_undefined(%{} = map) when not is_struct(map),
    do: for({key, value} <- map, value != nil, into: %{}, do: {key, drop_undefined(value)})

  defp drop_undefined(list) when is_list(list), do: Enum.map(list, &drop_undefined/1)
  defp drop_undefined(value), do: value

  # isomorphic/time.ts `monotonicTime()`: milliseconds, three decimals, since the VM started (the
  # viewer aligns it with the driver's by `wallTime`).
  defp monotonic_time do
    start = :erlang.system_info(:start_time)
    Float.floor(System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond) / 1000, 3)
  end
end
