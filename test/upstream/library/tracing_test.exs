defmodule PlaywrightEx.Library.TracingTest do
  @upstream "tests/library/tracing.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Runtime.Heap, only: [get: 2]
  import PlaywrightEx.Utils, only: [parse_trace_raw: 2]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Keyboard
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Mouse
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Runtime.Facade
  alias PlaywrightEx.Tracing

  @moduletag :page

  # test.skip(({ trace }) => trace === 'on');  -- the runner does not trace

  defp tracing(context), do: BrowserContext.tracing(context)

  # A call that JS starts without `await` (`page.click(...).catch(() => {})`): runs until its
  # message is sent, as the facade's waits do, and returns a promise handle.
  defp start(api_name, receiver, fun), do: Facade.promise(api_name, receiver, fun)
  defp host(server), do: URI.parse(server.prefix).authority

  @tag :tmp_dir
  test "should collect trace with resources, but no js", %{
    context: context,
    page: page,
    server: server,
    asset: asset,
    tmp_dir: tmp_dir
  } do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    Page.goto!(page, server.prefix <> "/frames/frame.html")
    Page.set_content!(page, "<button>Click</button>")
    Page.click!(page, ~s("Click"))
    Mouse.move!(Page.mouse(page), 20, 20)
    Mouse.dblclick!(Page.mouse(page), 30, 30)
    Keyboard.insert_text!(Page.keyboard(page), "abc")
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    Locator.set_input_files!(Page.locator(page, ~s(input[type="file"])), asset.("file-to-upload.txt"))
    # Give it some time to produce screenshots.
    Page.wait_for_timeout!(page, 2000)
    Page.close!(page)
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    %{events: events, actions: actions} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    assert hd(events)["type"] == "context-options"

    assert actions == [
             "Navigate #{host(server)}/frames/frame.html",
             "Set content",
             ~s{Click locator('text="Click"')},
             "Mouse move",
             "Double click",
             ~s(Insert "abc"),
             "Navigate #{host(server)}/input/fileupload.html",
             ~s{Set input files locator('input[type="file"]')},
             "Wait for timeout",
             "Close page"
           ]

    assert Enum.any?(events, &(&1["type"] == "frame-snapshot"))
    assert Enum.any?(events, &(&1["type"] == "screencast-frame"))

    style =
      Enum.find(
        events,
        &(&1["type"] == "resource-snapshot" and String.ends_with?(&1["snapshot"]["request"]["url"], "style.css"))
      )

    assert style
    assert style["snapshot"]["response"]["content"]["_file"]

    script =
      Enum.find(
        events,
        &(&1["type"] == "resource-snapshot" and String.ends_with?(&1["snapshot"]["request"]["url"], "script.js"))
      )

    assert script
    assert script["snapshot"]["response"]["content"]["_file"] == nil
  end

  @tag skip: "not ported: route"
  test "should use the correct title for event driven callbacks"

  @tag :tmp_dir
  test "should not collect snapshots by default", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context))
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<button>Click</button>")
    Page.click!(page, ~s("Click"))
    Page.close!(page)
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    %{events: events} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    refute Enum.any?(events, &(&1["type"] == "frame-snapshot"))
    refute Enum.any?(events, &(&1["type"] == "resource-snapshot"))
  end

  @tag :tmp_dir
  test "should not collect action screenshots and aria snapshots by default", %{
    context: context,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    Tracing.start!(tracing(context), snapshots: true)
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    %{events: events} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    refute Enum.any?(events, &(&1["type"] == "screenshot"))
    refute Enum.any?(events, &(&1["type"] == "aria-snapshot"))
  end

  @tag :tmp_dir
  test "should collect action screenshots", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), snapshots: %{screen: true})
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    %{events: events, resources: resources} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    click_call_id = Enum.find(events, &(&1["type"] == "before" and &1["method"] == "click"))["callId"]
    screenshots = Enum.filter(events, &(&1["type"] == "screenshot" and &1["callId"] == click_call_id))
    assert Enum.map(screenshots, & &1["phase"]) == ["before", "action", "after"]

    for screenshot <- screenshots do
      assert screenshot["file"] == "screenshots/#{click_call_id}-#{screenshot["phase"]}.png"
      buffer = resources[screenshot["file"]]
      # PNG.sync.read(buffer).width: the IHDR width
      <<_signature::binary-size(8), _length::32, "IHDR", width::32, _::binary>> = buffer
      assert width > 0
    end
  end

  @tag :tmp_dir
  test "should collect aria snapshots", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), snapshots: %{aria: true})
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    %{events: events, resources: resources} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    click_call_id = Enum.find(events, &(&1["type"] == "before" and &1["method"] == "click"))["callId"]
    aria_snapshots = Enum.filter(events, &(&1["type"] == "aria-snapshot" and &1["callId"] == click_call_id))
    assert Enum.map(aria_snapshots, & &1["phase"]) == ["before", "action", "after"]

    for aria_snapshot <- aria_snapshots do
      assert aria_snapshot["file"] == "aria/#{click_call_id}-#{aria_snapshot["phase"]}.json"
      snapshot = JSON.decode!(resources[aria_snapshot["file"]])
      assert has_button(snapshot) == true
    end
  end

  defp has_button(nodes) do
    Enum.any?(nodes, fn node ->
      is_map(node) and
        ((node["role"] == "button" and node["name"] == "Click target") or has_button(node["children"] || []))
    end)
  end

  @tag :tmp_dir
  test "can call tracing.group/groupEnd at any time and auto-close", %{
    context: context,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    Tracing.group!(tracing(context), "ignored")
    Tracing.group_end!(tracing(context))
    Tracing.group!(tracing(context), "ignored2")

    Tracing.start!(tracing(context))
    Tracing.group!(tracing(context), "actual")
    Page.goto!(page, server.empty_page)
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    Tracing.group!(tracing(context), "ignored3")
    Tracing.group_end!(tracing(context))
    Tracing.group_end!(tracing(context))
    Tracing.group_end!(tracing(context))

    %{events: events} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    groups = Enum.filter(events, &(&1["method"] == "tracingGroup"))
    assert length(groups) == 1
    assert hd(groups)["title"] == "actual"
    assert Enum.any?(events, &(&1["type"] == "after" and &1["callId"] == hd(groups)["callId"])) == true
  end

  @tag :tmp_dir
  test "should not include buffers in the trace", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), snapshots: true)
    Page.goto!(page, server.prefix <> "/empty.html")
    Page.screenshot!(page)
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))
    %{events: events, actionObjects: action_objects} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    screenshot_event = Enum.find(action_objects, &(&1["method"] == "screenshot"))

    phases =
      for e <- events,
          e["type"] == "frame-snapshot" and e["snapshot"]["callId"] == screenshot_event["callId"],
          do: e["snapshot"]["phase"]

    assert "before" in phases
    assert "after" in phases
    assert screenshot_event["result"] == %{"binary" => "<Buffer>"}
  end

  @tag skip: "not ported: storageState"
  test "should exclude internal pages"

  @tag skip: "not ported: APIRequestContext"
  test "should record context API request trace independently"

  @tag :tmp_dir
  test "should collect two traces", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<button>Click</button>")
    Page.click!(page, ~s("Click"))
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace1.zip"))

    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    Page.dblclick!(page, ~s("Click"))
    Page.close!(page)
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace2.zip"))

    %{events: events, actions: actions} = parse_trace_raw(Path.join(tmp_dir, "trace1.zip"), context)
    assert hd(events)["type"] == "context-options"
    assert actions == ["Navigate #{host(server)}/empty.html", "Set content", ~s{Click locator('text="Click"')}]

    %{events: events, actions: actions} = parse_trace_raw(Path.join(tmp_dir, "trace2.zip"), context)
    assert hd(events)["type"] == "context-options"
    assert actions == [~s{Double click locator('text="Click"')}, "Close page"]
  end

  @tag :tmp_dir
  test "should respect tracesDir and name", %{browser_type: browser_type, server: server, tmp_dir: tmp_dir} do
    traces_dir = Path.join(tmp_dir, "traces")
    browser = BrowserType.launch!(browser_type, traces_dir: traces_dir)
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    Tracing.start!(tracing(context), name: "name1", snapshots: true)
    Page.goto!(page, server.prefix <> "/one-style.html")
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace1.zip"))
    assert File.exists?(Path.join(traces_dir, "name1.trace")) == true
    assert File.exists?(Path.join(traces_dir, "name1.network")) == true

    Tracing.start_chunk!(tracing(context), name: "name2")
    Page.goto!(page, server.prefix <> "/har.html")
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace2.zip"))
    assert File.exists?(Path.join(traces_dir, "name2.trace")) == true
    assert File.exists?(Path.join(traces_dir, "name2.network")) == true

    resource_names = fn resources ->
      resources
      |> Map.keys()
      |> Enum.map(&Regex.replace(~r/^resources\/.*\.(html|css)$/, &1, "resources/XXX.\\1"))
      |> Enum.sort()
    end

    %{resources: resources, actions: actions} = parse_trace_raw(Path.join(tmp_dir, "trace1.zip"), context)
    Browser.close!(browser)
    assert actions == ["Navigate #{host(server)}/one-style.html"]

    assert resource_names.(resources) == [
             "resources/XXX.css",
             "resources/XXX.html",
             "trace.network",
             "trace.stacks",
             "trace.trace"
           ]

    %{resources: resources} = parse_trace_raw(Path.join(tmp_dir, "trace2.zip"), context)

    assert resource_names.(resources) == [
             "resources/XXX.css",
             "resources/XXX.html",
             "resources/XXX.html",
             "trace.network",
             "trace.stacks",
             "trace.trace"
           ]
  end

  @tag :tmp_dir
  test "should not include trace resources from the previous chunks", %{
    context: context,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true, sources: true)

    Tracing.start_chunk!(tracing(context))
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
        <style>
          @keyframes move {
            from { marign-left: 0; }
            to   { margin-left: 1000px; }
          }
          button {
            animation: 20s linear move;
            animation-iteration-count: infinite;
          }
        </style>
        <button>Click</button>
    """)

    Page.click!(page, ~s("Click"), force: true)
    # Give it enough time for both screenshots to get into the trace.
    Process.sleep(3000)
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace1.zip"))

    Tracing.start_chunk!(tracing(context))
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace2.zip"))

    %{resources: resources} = parse_trace_raw(Path.join(tmp_dir, "trace1.zip"), context)
    names = Map.keys(resources)
    assert Enum.count(names, &String.ends_with?(&1, ".html")) == 1
    jpegs = Enum.filter(names, &String.ends_with?(&1, ".jpeg"))
    # 1 source file for the test.
    assert Enum.count(names, &String.starts_with?(&1, "src/")) == 1

    %{resources: resources} = parse_trace_raw(Path.join(tmp_dir, "trace2.zip"), context)
    names = Map.keys(resources)
    # 1 network resource should be preserved.
    assert Enum.count(names, &String.ends_with?(&1, ".html")) == 1
    # screenshots from the previous chunk should not be preserved.
    refute Enum.any?(names, &(&1 in jpegs))
    # 0 source files for the second test.
    refute Enum.any?(names, &String.starts_with?(&1, "src/"))
  end

  @tag :tmp_dir
  test "should overwrite existing file", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true, sources: true)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<button>Click</button>")
    Page.click!(page, ~s("Click"))
    path = Path.join(tmp_dir, "trace1.zip")
    Tracing.stop!(tracing(context), path: path)

    %{resources: resources} = parse_trace_raw(path, context)
    assert Enum.count(Map.keys(resources), &String.ends_with?(&1, ".html")) == 1

    Tracing.start!(tracing(context), screenshots: true, snapshots: true, sources: true)
    Tracing.stop!(tracing(context), path: path)

    %{resources: resources} = parse_trace_raw(path, context)
    refute Enum.any?(Map.keys(resources), &String.ends_with?(&1, ".html"))
  end

  @tag :tmp_dir
  test "should collect sources", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), sources: true)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<button>Click</button>")
    Page.click!(page, ~s("Click"))
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace1.zip"))

    %{resources: resources} = parse_trace_raw(Path.join(tmp_dir, "trace1.zip"), context)
    source_names = resources |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "src/"))
    assert length(source_names) == 1
    # Deviation: the source is this .exs file.
    assert hd(source_names) =~ ~r/^src\/[0-9a-f]{40}\.exs$/
    source_file = resources[hd(source_names)]
    this_file = File.read!(__ENV__.file)
    assert source_file == this_file
  end

  @tag skip: "not ported: route"
  test "should record network failures"

  @tag :tmp_dir
  test "should recover tracing after a failed stop", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context))
    # Saving fails: a parent of the destination is a file, not a directory.
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "")
    assert {:error, error} = Tracing.stop(tracing(context), path: Path.join(blocker, "trace1.zip"))
    assert error.message =~ ~r/ENOTDIR|ENOENT|EEXIST/

    # The failed stop must not wedge tracing for the rest of the context lifetime.
    Tracing.start!(tracing(context))
    Page.goto!(page, server.prefix <> "/input/button.html")
    Page.click!(page, "button")
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace2.zip"))

    %{events: events, actions: actions} = parse_trace_raw(Path.join(tmp_dir, "trace2.zip"), context)
    assert hd(events)["type"] == "context-options"
    assert "Click locator('button')" in actions
  end

  @tag :tmp_dir
  test "should release the stack session when saving the trace fails", %{browser_type: browser_type, tmp_dir: tmp_dir} do
    # Override the test runner's tracesDir, so that the stack session owns a temporary directory.
    browser = BrowserType.launch!(browser_type)

    try do
      context = Browser.new_context!(browser)
      Tracing.start!(tracing(context))
      stacks_dir = Path.dirname(get(tracing(context), :_stacksId))
      assert File.exists?(stacks_dir) == true

      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "")
      assert {:error, error} = Tracing.stop(tracing(context), path: Path.join(blocker, "trace.zip"))
      assert error.message =~ ~r/ENOTDIR|ENOENT|EEXIST/
      assert File.exists?(stacks_dir) == false
    after
      Browser.close!(browser)
    end
  end

  @tag :tmp_dir
  test "should not crash when browser closes mid-trace", %{browser_type: browser_type, server: server} do
    browser = BrowserType.launch!(browser_type)
    page = Browser.new_page!(browser)
    Tracing.start!(tracing(Page.context(page)), snapshots: true, screenshots: true)
    Page.goto!(page, server.empty_page)
    Browser.close!(browser)
    # Give it some time to throw errors
    Process.sleep(1000)
  end

  test "should survive browser.close with auto-created traces dir", %{browser_type: browser_type} do
    # (browserType as any)._playwright._defaultTracesDir = undefined;  -- the runner sets no traces dir
    browser = BrowserType.launch!(browser_type)
    page = Browser.new_page!(browser)
    Tracing.start!(tracing(Page.context(page)))

    # `done.value = true` is `Task.shutdown/2` below.
    go =
      Task.async(fn ->
        Stream.repeatedly(fn ->
          # Produce a lot of operations to make sure tracing operations are enqueued.
          for _ <- 1..100, do: Task.start(fn -> Page.evaluate(page, "1 + 1") end)
          Process.sleep(250)
        end)
        |> Stream.run()
      end)

    Process.sleep(1000)

    # Close the browser and give it some time to fail.
    Browser.close!(browser)
    Process.sleep(500)

    Task.shutdown(go, :brutal_kill)
  end

  test "should not stall on dialogs", %{page: page, context: context, server: server} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    Page.goto!(page, server.empty_page)

    Page.on(page, :dialog, fn dialog -> Dialog.accept!(dialog) end)

    Page.evaluate!(page, "() => { confirm('are you sure'); }")
    Tracing.stop!(tracing(context))
  end

  # for (const params of [fit, crop, scale]) browserTest(`should produce screencast frames ${params.id}`)  -- not ported: JPEG decoding

  @tag :tmp_dir
  test "should include interrupted actions", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<button>Click</button>")
    start("page.click", page, fn -> PlaywrightEx.Client.Page.click(page, ~s("ClickNoButton"), %{}) end)
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))
    BrowserContext.close!(context)

    %{actions: actions} = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    assert ~s{Click locator('text="ClickNoButton"')} in actions
  end

  test "should throw when starting with different options", %{context: context} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    {:error, error} = Tracing.start(tracing(context), screenshots: false, snapshots: false)
    assert error.message =~ "Tracing has been already started"
  end

  @tag :tmp_dir
  test "should throw when stopping without start", %{context: context, tmp_dir: tmp_dir} do
    {:error, error} = Tracing.stop(tracing(context), path: Path.join(tmp_dir, "trace.zip"))
    assert error.message =~ "Must start tracing before stopping"
  end

  test "should not throw when stopping without start but not exporting", %{context: context} do
    Tracing.stop!(tracing(context))
  end

  @tag :tmp_dir
  test "start should return a disposable that discards the trace", %{
    context: context,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    disposable = Tracing.start!(tracing(context))
    Page.goto!(page, server.empty_page)
    Disposable.dispose!(disposable)
    {:error, error} = Tracing.stop(tracing(context), path: Path.join(tmp_dir, "trace.zip"))
    assert error.message =~ "Must start tracing before stopping"
  end

  @tag :tmp_dir
  test "startChunk should return a disposable that discards the chunk", %{
    context: context,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    Tracing.start!(tracing(context))
    disposable = Tracing.start_chunk!(tracing(context))
    Page.goto!(page, server.empty_page)
    Disposable.dispose!(disposable)
    {:error, error} = Tracing.stop_chunk(tracing(context), path: Path.join(tmp_dir, "trace.zip"))
    assert error.message =~ "Must start tracing before stopping"
  end

  @tag :tmp_dir
  test "should work with multiple chunks", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    Page.goto!(page, server.prefix <> "/frames/frame.html")

    Tracing.start_chunk!(tracing(context))
    Page.set_content!(page, "<button>Click</button>")
    Page.click!(page, ~s("Click"))
    start("page.click", page, fn -> PlaywrightEx.Client.Page.click(page, ~s("ClickNoButton"), %{timeout: 0}) end)
    Page.evaluate!(page, "() => {}")
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    Tracing.start_chunk!(tracing(context))
    Page.hover!(page, ~s("Click"))
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace2.zip"))

    Tracing.start_chunk!(tracing(context))
    Page.click!(page, ~s("Click"))
    # Should stop without a path.
    Tracing.stop_chunk!(tracing(context))

    trace1 = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    assert hd(trace1.events)["type"] == "context-options"

    assert trace1.actions == [
             "Set content",
             ~s{Click locator('text="Click"')},
             ~s{Click locator('text="ClickNoButton"')},
             "Evaluate"
           ]

    assert Enum.any?(trace1.events, &(&1["type"] == "frame-snapshot"))

    assert Enum.any?(
             trace1.events,
             &(&1["type"] == "resource-snapshot" and String.ends_with?(&1["snapshot"]["request"]["url"], "style.css"))
           )

    trace2 = parse_trace_raw(Path.join(tmp_dir, "trace2.zip"), context)
    assert hd(trace2.events)["type"] == "context-options"
    assert trace2.actions == [~s{Hover locator('text="Click"')}]
    assert Enum.any?(trace2.events, &(&1["type"] == "frame-snapshot"))

    assert Enum.any?(
             trace2.events,
             &(&1["type"] == "resource-snapshot" and String.ends_with?(&1["snapshot"]["request"]["url"], "style.css"))
           )
  end

  @tag :tmp_dir
  test "should export trace concurrently to second navigation", %{
    context: context,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    for timeout <- 0..180//20 do
      Tracing.start!(tracing(context), screenshots: true, snapshots: true)
      Page.goto!(page, server.prefix <> "/grid.html")

      # Navigate to the same page to produce the same trace resources
      # that might be concurrently exported.
      promise = Task.async(fn -> Page.goto!(page, server.prefix <> "/grid.html") end)
      Page.wait_for_timeout!(page, timeout)
      Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))
      Task.await(promise)
    end
  end

  test "should not hang for clicks that open dialogs", %{context: context, page: page} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    dialog_promise = Page.wait_for_event(page, :dialog)
    Page.set_content!(page, "<div onclick='window.alert(123)'>Click me</div>")
    Page.click(page, "div", timeout: 3500)
    dialog = Promise.await!(dialog_promise)
    Dialog.dismiss!(dialog)
    Tracing.stop!(tracing(context))
  end

  @tag :tmp_dir
  test "should ignore iframes in head", %{context: context, page: page, server: server, tmp_dir: tmp_dir} do
    Page.goto!(page, server.prefix <> "/input/button.html")

    Page.evaluate!(page, """
    () => {
      document.head.appendChild(document.createElement('iframe'));
      // Add iframe in a shadow tree.
      const div = document.createElement('div');
      document.head.appendChild(div);
      const shadow = div.attachShadow({ mode: 'open' });
      shadow.appendChild(document.createElement('iframe'));
    }
    """)

    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    Page.click!(page, "button")
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace.zip"))

    trace = parse_trace_raw(Path.join(tmp_dir, "trace.zip"), context)
    assert trace.actions == ["Click locator('button')"]
    assert Enum.find(trace.events, &(&1["type"] == "frame-snapshot"))

    refute Enum.find(
             trace.events,
             &(&1["type"] == "frame-snapshot" and JSON.encode!(&1["snapshot"]["html"]) =~ "IFRAME")
           )
  end

  @tag :tmp_dir
  test "should hide internal stack frames", %{context: context, page: page, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context), screenshots: true, snapshots: true)
    test = self()

    # Deviation: no tail calls into the client, so that the BEAM keeps this file's frames.
    Page.on(page, :dialog, fn dialog ->
      send(test, {:eval, start("page.evaluate", page, fn -> [PlaywrightEx.Client.Page.evaluate(page, "2+2")] end)})
      Dialog.dismiss(dialog)
      :ok
    end)

    Page.set_content!(page, "<div onclick='window.alert(123)'>Click me</div>")
    Page.click!(page, "div")
    assert_receive {:eval, eval_promise}
    Promise.await!(eval_promise)
    trace_path = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_path)

    trace = parse_trace_raw(trace_path, context)
    actions = Enum.filter(trace.actionObjects, &(&1["class"] != "Tracing"))
    assert length(actions) == 4
    for action <- actions, do: assert(relative_stack(action, trace.stacks) == [Path.basename(__ENV__.file)])
  end

  @tag skip: "not ported: expect"
  test "should hide internal stack frames in expect"

  @tag skip: "not ported: APIRequestContext"
  test "should record global request trace"

  @tag skip: "not ported: APIRequestContext"
  test "should store global request traces separately"

  @tag skip: "not ported: APIRequestContext"
  test "should store postData for global request"

  @tag skip: "not ported: the runner's tracesDir (artifactsFolderName), expect.toPass"
  test "should not flush console events"

  @tag :tmp_dir
  test "should flush console events on tracing stop", %{context: context, page: page, tmp_dir: tmp_dir} do
    Tracing.start!(tracing(context))
    test = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Page.on(page, :console, fn _ ->
      if Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) == 100, do: send(test, :done)
    end)

    Page.evaluate!(page, """
    () => {
      window.builtins.setTimeout(() => {
        for (let i = 0; i < 100; ++i)
          console.log('hello ' + i);
      });
    }
    """)

    assert_receive :done, 10_000
    trace_path = Path.join(tmp_dir, "trace.zip")
    Tracing.stop!(tracing(context), path: trace_path)
    trace = parse_trace_raw(trace_path, context)
    events = Enum.filter(trace.events, &(&1["type"] == "console"))
    assert length(events) == 100
  end

  @tag :tmp_dir
  test "should not emit after w/o before", %{browser_type: browser_type, tmp_dir: tmp_dir} do
    traces_dir = Path.join(tmp_dir, "traces")
    browser = BrowserType.launch!(browser_type, traces_dir: traces_dir)
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)

    Tracing.start!(tracing(context), name: "name1", snapshots: true)

    # One synchronous JS section: the console event can't arrive before the wait is set up.
    {evaluate_promise, console_promise} =
      Api.call(nil, page, fn ->
        evaluate_promise =
          start("page.evaluate", page, fn ->
            PlaywrightEx.Client.Page.evaluate(page, """
            () => {
              console.log('started');
              return new Promise(f => window.callback = f);
            }
            """)
          end)

        {evaluate_promise, Page.wait_for_event(page, :console)}
      end)

    Promise.await!(console_promise)
    Tracing.stop_chunk!(tracing(context), path: Path.join(tmp_dir, "trace1.zip"))
    assert File.exists?(Path.join(traces_dir, "name1.trace")) == true

    Tracing.start_chunk!(tracing(context), name: "name2")
    Page.evaluate_handle!(page, "() => window.callback()")
    Promise.await(evaluate_promise)
    Tracing.stop!(tracing(context), path: Path.join(tmp_dir, "trace2.zip"))
    assert File.exists?(Path.join(traces_dir, "name2.trace")) == true

    Browser.close!(browser)

    call_id = fn e -> e["callId"] |> String.split("@") |> Enum.at(1) |> String.to_integer() end

    sanitize = fn events ->
      before_after = Enum.filter(events, &(&1["type"] in ["after", "before"]))
      min_call_id = before_after |> Enum.map(call_id) |> Enum.min(fn -> 0 end)
      Enum.map(before_after, &%{type: &1["type"], callId: call_id.(&1) - min_call_id, title: &1["title"]})
    end

    %{events: events} = parse_trace_raw(Path.join(tmp_dir, "trace1.zip"), context)
    sanitized = sanitize.(events)

    assert [
             %{type: "before", callId: call1, title: nil},
             %{type: "before", callId: wait_before, title: ~s(Wait for event "console")},
             %{type: "after", callId: wait_after, title: nil}
           ] = sanitized

    assert is_integer(call1)
    assert wait_before == wait_after

    # Deviation: the callIds are offset against each trace's minimum, as upstream's
    # `minCallId` is shared across both traces; compare the raw ids instead.
    raw_call1 = events |> Enum.find(&(&1["type"] == "before")) |> call_id.()

    %{events: events} = parse_trace_raw(Path.join(tmp_dir, "trace2.zip"), context)
    sanitized = sanitize.(events)

    assert [
             %{type: "before", callId: _, title: nil},
             %{type: "after", callId: _, title: nil}
           ] = sanitized

    [call2before, call2after] = events |> Enum.filter(&(&1["type"] in ["after", "before"])) |> Enum.map(call_id)
    assert call2before > raw_call1
    assert call2after == call2before
  end

  @tag skip: "not ported: TestServer.onceWebSocketConnection"
  test "should save trace while a WebSocket keeps streaming frames"

  # Deviation: the test file's frames by basename, without the ExUnit runner and OTP frames
  # below them (Playwright Test filters its own frames).
  defp relative_stack(action, stacks) do
    stack = stacks[action["callId"]] || []

    for %{"file" => file} <- stack,
        not String.contains?(file, "ex_unit/") and not String.ends_with?(file, ".erl"),
        do: Path.basename(file)
  end
end
