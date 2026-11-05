defmodule PlaywrightEx.Utils do
  @upstream "tests/config/utils.ts"
  @moduledoc "Port of upstream `#{@upstream}`: helpers of the mirrored specs, on the public API."

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  def attach_frame(page, frame_id, url) do
    handle =
      Page.evaluate_handle!(
        page,
        """
        async ({ frameId, url }) => {
          const frame = document.createElement('iframe');
          frame.src = url;
          frame.id = frameId;
          document.body.appendChild(frame);
          await new Promise(x => frame.onload = x);
          return frame;
        }
        """,
        %{frameId: frame_id, url: url}
      )

    ElementHandle.content_frame!(JSHandle.as_element(handle))
  end

  def detach_frame(page, frame_id) do
    Page.evaluate!(page, "frameId => { document.getElementById(frameId).remove(); }", frame_id)
  end

  def verify_viewport(page, width, height) do
    import ExUnit.Assertions
    assert Page.viewport_size(page).width == width
    assert Page.viewport_size(page).height == height
    assert Page.evaluate!(page, "window.innerWidth") == width
    assert Page.evaluate!(page, "window.innerHeight") == height
  end

  @doc "`expectedSSLError(browserName, platform, channel)`; `platform` is `process.platform`."
  def expected_ssl_error(browser_name, platform \\ platform(), channel \\ nil) do
    cond do
      browser_name == "chromium" ->
        ~r/net::(ERR_CERT_AUTHORITY_INVALID|ERR_CERT_INVALID)/

      browser_name == "webkit" ->
        cond do
          platform == "darwin" -> ~r/The certificate for this server is invalid/
          platform == "win32" and channel != "webkit-wsl" -> ~r/SSL peer certificate or SSH remote key was not OK/
          true -> ~r/Unacceptable TLS certificate|Operation was cancelled/
        end

      browser_name == "firefox" and is_bidi_channel(channel) ->
        ~r/MOZILLA_PKIX_ERROR_SELF_SIGNED_CERT/

      true ->
        ~r/SSL_ERROR_UNKNOWN/
    end
  end

  def is_bidi_channel(channel) do
    String.starts_with?(channel || "", ["bidi-chrom", "moz-firefox"])
  end

  # `process.platform`.
  defp platform do
    case :os.type() do
      {:unix, :darwin} -> "darwin"
      {:win32, _} -> "win32"
      {:unix, os} -> to_string(os)
    end
  end

  # chromiumVersionLessThan, suppressCertificateWarning  -- not ported: not needed yet
  @doc """
  `parseTraceCoverage(file)`: the merged istanbul coverage of the trace (string-keyed maps,
  `isomorphic/istanbulCoverage.ts` `mergeIstanbulCoverage`), `nil` when it has none.
  Takes a handle, as `parse_trace_raw/2`.
  """
  def parse_trace_coverage(file, handle) do
    %{resources: resources} = parse_trace_raw(file, handle)
    entries = resources |> Map.keys() |> Enum.filter(&Regex.match?(~r/(^|-)trace\.coverage$/, &1))

    if entries != [] do
      entries
      |> Enum.reduce(%{}, fn entry, coverage -> merge_istanbul_coverage(coverage, JSON.decode!(resources[entry])) end)
    end
  end

  @doc """
  `parseTraceRaw(file)`: `%{events, resources, actions, actionObjects, stacks}` with the JSON
  events as string-keyed maps. Deviation: takes a handle (`playwright`, a page, ...) whose
  connection renders selectors in titles (`LocalUtils.asLocatorDescription`, as
  `isomorphic/protocolFormatter.ts` does with `locatorGenerators`).
  """
  def parse_trace_raw(file, handle) do
    {:ok, entries} = :zip.unzip(String.to_charlist(file), [:memory])
    entries = Enum.map(entries, fn {name, data} -> {to_string(name), data} end)
    resources = Map.new(entries)

    lines = fn suffix ->
      for {name, data} <- entries,
          String.ends_with?(name, suffix),
          line <- String.split(data, "\n"),
          line != "",
          do: JSON.decode!(line)
    end

    trace_events = lines.(".trace")

    action_map = Enum.reduce(trace_events, %{order: [], map: %{}}, &add_trace_event/2)

    events = trace_events ++ lines.(".network")

    stacks =
      for {name, data} <- entries, String.ends_with?(name, ".stacks"), reduce: %{} do
        acc -> Map.merge(acc, parse_client_side_call_metadata(JSON.decode!(data)))
      end

    action_objects = action_map.order |> Enum.map(&action_map.map[&1]) |> Enum.sort_by(& &1["startTime"])

    %{
      events: events,
      resources: resources,
      actions: Enum.map(action_objects, &render_full_title_for_call(&1, handle)),
      actionObjects: action_objects,
      stacks: stacks
    }
  end

  # parseTrace, parseHar  -- not ported: trace viewer, HAR
  # waitForTestLog  -- not ported: ConsoleMessage

  def rafraf(target, count \\ 1) do
    for _ <- 1..count//1 do
      target.__struct__
      |> facade()
      |> apply(:evaluate!, [
        target,
        "async () => { await new Promise(f => window.builtins.requestAnimationFrame(() => window.builtins.requestAnimationFrame(f))); }"
      ])
    end

    nil
  end

  def ensure_some_frames(page) do
    rafraf(page, 100)
    Page.screenshot!(page)
  end

  def round_box(box) do
    %{x: round(box.x), y: round(box.y), width: round(box.width), height: round(box.height)}
  end

  # unshift, stripAnsi, inheritAndCleanEnv  -- not ported: not needed yet

  defp add_trace_event(%{"type" => "before", "callId" => call_id} = event, acc) do
    action = Map.merge(event, %{"type" => "action", "endTime" => 0})
    %{acc | order: acc.order ++ [call_id], map: Map.put(acc.map, call_id, action)}
  end

  defp add_trace_event(%{"type" => "input", "callId" => call_id} = event, acc),
    do: update_in(acc, [:map, call_id], &Map.put(&1, "point", event["point"]))

  defp add_trace_event(%{"type" => "after", "callId" => call_id} = event, acc) do
    update_in(acc, [:map, call_id], fn existing ->
      Map.merge(existing, %{"endTime" => event["endTime"], "error" => event["error"], "result" => event["result"]})
    end)
  end

  defp add_trace_event(_event, acc), do: acc

  # isomorphic/trace/traceUtils.ts
  defp parse_client_side_call_metadata(%{"files" => files, "stacks" => stacks}) do
    Map.new(stacks, fn [id, ff] ->
      {id,
       Enum.map(ff, fn [file, line, column, function] ->
         %{"file" => Enum.at(files, file), "line" => line, "column" => column, "function" => function}
       end)}
    end)
  end

  # isomorphic/protocolFormatter.ts renderFullTitleForCall({ ...action, type: action.class })
  defp render_full_title_for_call(action, handle) do
    meta = PlaywrightEx.Protocol.Metainfo.get_metainfo(%{type: action["class"], method: action["method"]}) || %{}
    title = render_format(action["title"] || meta[:title] || action["method"], action["params"], handle)

    subtitle =
      if format = meta[:subtitle] do
        rendered = render_format(format, action["params"], handle)
        if !String.contains?(rendered, "{"), do: rendered
      end

    if subtitle, do: "#{title} #{subtitle}", else: title
  end

  defp render_format(format, params, handle) do
    Regex.replace(~r/\{([^}]+)\}/, format, fn full_match, alternatives ->
      format_protocol_param(params, alternatives, handle) || full_match
    end)
  end

  defp format_protocol_param(nil, _alternatives, _handle), do: nil

  defp format_protocol_param(params, alternatives, handle) do
    alternatives
    |> String.split("|")
    |> Enum.find_value(&format_protocol_param_name(params, &1, handle))
    |> then(&(&1 && String.replace(&1, "\n", "\\n")))
  end

  defp format_protocol_param_name(%{"url" => url}, "url", _handle) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme == "data" -> "data:"
      uri.scheme in ["about", "chrome", "edge"] -> url
      uri.host -> "#{uri.host}#{uri.port && ":#{uri.port}"}#{uri.path}#{uri.query && "?#{uri.query}"}"
      true -> url
    end
  end

  defp format_protocol_param_name(params, name, handle) do
    value = deep_param(params, name)

    if value && (name == "selector" or String.ends_with?(name, ".selector")),
      do: as_locator_description(handle, value),
      else: value
  end

  defp deep_param(params, name) do
    name
    |> String.split(".")
    |> Enum.reduce_while(params, fn token, current ->
      if is_map(current), do: {:cont, current[token]}, else: {:halt, nil}
    end)
    |> case do
      nil -> nil
      value when is_binary(value) -> value
      value -> to_string(JSON.encode!(value))
    end
  end

  defp as_locator_description(handle, selector) do
    import PlaywrightEx.Runtime.Heap
    local_utils = PlaywrightEx.Client.Connection.local_utils(get(handle, :_connection))

    PlaywrightEx.Runtime.Api.call(nil, local_utils, fn ->
      PlaywrightEx.Client.ChannelOwner.channel_call(local_utils, :asLocatorDescription, %{
        selector: selector,
        sdkLanguage: "javascript"
      }).description
    end)
  end

  # `Page | Frame`: the facade module of a client handle.
  defp facade(PlaywrightEx.Client.Page), do: PlaywrightEx.Page
  defp facade(PlaywrightEx.Client.Frame), do: PlaywrightEx.Frame

  @doc """
  `expect(fn).toPass(options)` (`expect.ts`): calls `fun` until it returns without raising
  (an `ExUnit.AssertionError` or any other exception), with upstream's default `intervals`
  (100, 250, 500, 1000 ms) until `timeout` (deviation: default 5000 ms, upstream's is the test
  timeout). Returns `fun`'s value; re-raises the last error on timeout.
  """
  def to_pass(fun, options \\ []) do
    timeout = Keyword.get(options, :timeout, 5000)
    intervals = Keyword.get(options, :intervals, [100, 250, 500, 1000])
    deadline = System.monotonic_time(:millisecond) + timeout
    do_to_pass(fun, intervals, deadline)
  end

  @doc """
  `expect.poll(fn, options).<matcher>`: polls `value_fun` until `assertion` (called with its
  value) passes, as `to_pass/2` does. `poll(fn -> received end, &assert(&1 == [1, 2]))`.
  Returns the last value.
  """
  def poll(value_fun, assertion, options \\ []) do
    to_pass(
      fn ->
        value = value_fun.()
        assertion.(value)
        value
      end,
      options
    )
  end

  defp do_to_pass(fun, intervals, deadline) do
    fun.()
  rescue
    error ->
      [interval | rest] = intervals
      now = System.monotonic_time(:millisecond)
      if now >= deadline, do: reraise(error, __STACKTRACE__)
      Process.sleep(min(interval, deadline - now))
      do_to_pass(fun, if(rest == [], do: intervals, else: rest), deadline)
  end

  # isomorphic/istanbulCoverage.ts
  defp merge_istanbul_coverage(into, data) do
    Enum.reduce(data, into, fn {file, file_cov}, into ->
      existing =
        into[file] ||
          %{
            "path" => file_cov["path"],
            "statementMap" => %{},
            "fnMap" => %{},
            "branchMap" => %{},
            "s" => %{},
            "f" => %{},
            "b" => %{}
          }

      Map.put(into, file, merge_file_coverage(existing, file_cov))
    end)
  end

  defp merge_file_coverage(existing, file_cov) do
    # The maps can arrive late if the report that carried them was lost.
    existing =
      if file_cov["statementMap"] && map_size(existing["statementMap"]) == 0,
        do: zero_fill(existing, file_cov),
        else: existing

    add = fn counters, key, count -> Map.update(counters, key, count, &(&1 + count)) end
    s = Enum.reduce(file_cov["s"], existing["s"], fn {k, v}, acc -> add.(acc, k, v) end)
    f = Enum.reduce(file_cov["f"], existing["f"], fn {k, v}, acc -> add.(acc, k, v) end)

    b =
      Enum.reduce(file_cov["b"], existing["b"], fn {k, counts}, acc -> Map.put(acc, k, add_branches(acc[k], counts)) end)

    %{existing | "s" => s, "f" => f, "b" => b}
  end

  defp zero_fill(existing, file_cov) do
    statement_map = file_cov["statementMap"]
    fn_map = file_cov["fnMap"] || %{}
    branch_map = file_cov["branchMap"] || %{}
    zeros = fn map -> Map.new(map, fn {k, _} -> {k, 0} end) end
    branch_zeros = Map.new(branch_map, fn {k, branch} -> {k, Enum.map(branch["locations"], fn _ -> 0 end)} end)

    # Reports only carry the counters that were hit, zero fill the rest.
    %{
      existing
      | "statementMap" => statement_map,
        "fnMap" => fn_map,
        "branchMap" => branch_map,
        "s" => Map.merge(zeros.(statement_map), existing["s"]),
        "f" => Map.merge(zeros.(fn_map), existing["f"]),
        "b" => Map.merge(branch_zeros, existing["b"])
    }
  end

  defp add_branches(branches, counts) do
    branches = branches || []
    padded = branches ++ List.duplicate(0, max(length(counts) - length(branches), 0))
    padded |> Enum.with_index() |> Enum.map(fn {c, i} -> c + (Enum.at(counts, i) || 0) end)
  end
end
