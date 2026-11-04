defmodule PlaywrightEx.Library.ScreencastTest do
  @upstream "tests/library/screencast.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [ensure_some_frames: 1]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.Screencast

  # config/errors.ts
  @k_target_closed_error_message "Target page, context or browser has been closed"

  # test.skip(mode !== 'default'), test.skip(video === 'on'), test.slow()  -- always default mode, no runner video

  # `frames.push(...)` from the listener process.
  defp collector do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {fn frame -> Agent.update(agent, &(&1 ++ [frame])) end, fn -> Agent.get(agent, & &1) end}
  end

  test "screencast.start delivers frames via onFrame callback", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 1000, height: 400})
    page = BrowserContext.new_page!(context)

    {push, frames} = collector()
    size = %{width: 500, height: 400}
    Screencast.start!(Page.screencast(page), on_frame: fn %{data: data} -> push.(data) end, size: size)
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
    ensure_some_frames(page)
    Screencast.stop!(Page.screencast(page))

    assert length(frames.()) > 0

    for frame <- frames.() do
      # Each frame must be a valid JPEG (starts with FF D8)
      assert <<0xFF, 0xD8, _::binary>> = frame
      %{width: width, height: height} = jpeg_dimensions(frame)
      # Frame should be scaled down to fit the maximum size.
      assert width == 500
      assert height == 200
    end

    BrowserContext.close!(context)
  end

  @tag skip: "not ported: async onFrame (a listener awaiting a promise of its own)"
  test "applies backpressure while async onFrame callback is pending"

  test "onFrame receives viewport size", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 1000, height: 400})
    page = BrowserContext.new_page!(context)

    {push, frames} = collector()

    Screencast.start!(Page.screencast(page),
      on_frame: fn %{timestamp: timestamp, viewportWidth: viewport_width, viewportHeight: viewport_height} ->
        push.(%{timestamp: timestamp, viewportWidth: viewport_width, viewportHeight: viewport_height})
      end,
      size: %{width: 500, height: 400}
    )

    Page.goto!(page, server.empty_page)
    ensure_some_frames(page)
    Screencast.stop!(Page.screencast(page))

    assert length(frames.()) > 0

    for frame <- frames.() do
      assert frame.viewportWidth == 1000
      assert frame.viewportHeight == 400
      assert is_number(frame.timestamp)
    end

    BrowserContext.close!(context)
  end

  test "start throws if screencast is already started", %{browser: browser} do
    context = Browser.new_context!(browser, viewport: %{width: 500, height: 400})
    page = BrowserContext.new_page!(context)

    Screencast.start!(Page.screencast(page), on_frame: fn _ -> nil end)
    assert {:error, error} = Screencast.start(Page.screencast(page), on_frame: fn _ -> nil end)
    assert error.message =~ "Screencast is already started"

    Screencast.stop!(Page.screencast(page))
    BrowserContext.close!(context)
  end

  test "start allows restart with different options after stop", %{browser: browser} do
    context = Browser.new_context!(browser, viewport: %{width: 500, height: 400})
    page = BrowserContext.new_page!(context)

    Screencast.start!(Page.screencast(page), on_frame: fn _ -> nil end, size: %{width: 500, height: 400})
    Screencast.stop!(Page.screencast(page))
    # Different options should succeed once the previous screencast is stopped.
    Screencast.start!(Page.screencast(page), on_frame: fn _ -> nil end, size: %{width: 320, height: 240})
    Screencast.stop!(Page.screencast(page))
    BrowserContext.close!(context)
  end

  test "start returns a disposable that stops screencast", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 500, height: 400})
    page = BrowserContext.new_page!(context)

    {push, frames} = collector()

    Screencast.start!(Page.screencast(page),
      on_frame: fn %{data: data} -> push.(data) end,
      size: %{width: 500, height: 400}
    )

    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
    ensure_some_frames(page)
    Screencast.stop!(Page.screencast(page))

    frame_count_after_dispose = length(frames.())
    assert frame_count_after_dispose > 0

    # No more frames should arrive after dispose.
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'blue'")
    ensure_some_frames(page)
    assert length(frames.()) == frame_count_after_dispose

    BrowserContext.close!(context)
  end

  @tag :tmp_dir
  test "start/stop twice without path creates two files in artifactsDir", %{
    browser_type: browser_type,
    tmp_dir: tmp_dir
  } do
    artifacts_dir = Path.join(tmp_dir, "artifacts")
    browser = BrowserType.launch!(browser_type, artifacts_dir: artifacts_dir)
    size = %{width: 800, height: 800}
    context = Browser.new_context!(browser, viewport: size)
    page = BrowserContext.new_page!(context)

    Screencast.start!(Page.screencast(page), path: Path.join(tmp_dir, "video1.webm"), size: size)
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
    ensure_some_frames(page)
    Screencast.stop!(Page.screencast(page))

    Screencast.start!(Page.screencast(page), path: Path.join(tmp_dir, "video2.webm"), size: size)
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'blue'")
    ensure_some_frames(page)
    Screencast.stop!(Page.screencast(page))

    video_files = artifacts_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".webm"))
    assert length(video_files) == 2

    BrowserContext.close!(context)
    Browser.close!(browser)
  end

  @tag :tmp_dir
  test "start should work when recordVideo is set", %{browser: browser, tmp_dir: tmp_dir} do
    auto_dir = Path.join(tmp_dir, "auto")
    manual_dir = Path.join(tmp_dir, "manual")
    context = Browser.new_context!(browser, record_video: %{dir: auto_dir})
    page = BrowserContext.new_page!(context)

    Screencast.start!(Page.screencast(page), path: Path.join(manual_dir, "video.webm"))
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'blue'")
    ensure_some_frames(page)
    Screencast.stop!(Page.screencast(page))
    video_files1 = manual_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".webm"))
    assert length(video_files1) == 1

    BrowserContext.close!(context)
    video_files2 = auto_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".webm"))
    assert length(video_files2) == 1
  end

  @tag skip: "not ported: VideoPlayer (ffmpeg)"
  test "start should record video with the requested fps"

  @tag :page
  @tag :tmp_dir
  test "start should throw on invalid fps", %{page: page, tmp_dir: tmp_dir} do
    {:error, error} = Screencast.start(Page.screencast(page), path: Path.join(tmp_dir, "video.webm"), fps: -1)
    assert error.message =~ ~s("fps" must be a positive number, got -1)
  end

  @tag :page
  @tag :tmp_dir
  test "start should fail when another recording is in progress", %{page: page, tmp_dir: tmp_dir} do
    Screencast.start!(Page.screencast(page), path: Path.join(tmp_dir, "video.webm"))
    {:error, error} = Screencast.start(Page.screencast(page), path: Path.join(tmp_dir, "video2.webm"))
    assert error.message =~ "Screencast is already started"
  end

  test "stop should not fail when no recording is in progress", %{browser: browser} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    # stop() is a no-op when screencast is not started.
    Screencast.stop!(Page.screencast(page))
    BrowserContext.close!(context)
  end

  @tag :tmp_dir
  test "start should finish when page is closed", %{browser: browser, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    video_path = Path.join(tmp_dir, "video.webm")
    Screencast.start!(Page.screencast(page), path: video_path, size: %{width: 800, height: 800})
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
    ensure_some_frames(page)
    Page.close!(page)
    {:error, error} = Screencast.stop(Page.screencast(page))
    assert error.message =~ @k_target_closed_error_message
    BrowserContext.close!(context)
  end

  @tag skip: "not ported: VideoPlayer (ffmpeg)"
  test "empty video"

  @tag skip: "not ported: VideoPlayer (ffmpeg)"
  test "start dispose stops recording"

  defp jpeg_dimensions(buffer), do: jpeg_dimensions(buffer, 2)

  # SOF markers: C0 (baseline), C2 (progressive), C1, C3, C5-C7, C9-CB, CD-CF
  defp jpeg_dimensions(buffer, i) when i < byte_size(buffer) - 8 do
    <<_::binary-size(^i), 0xFF, marker, segment_length::16, _::binary>> = buffer

    if marker in 0xC0..0xC3 or marker in 0xC5..0xC7 or marker in 0xC9..0xCB or marker in 0xCD..0xCF do
      offset = i + 5
      <<_::binary-size(^offset), height::16, width::16, _::binary>> = buffer
      %{width: width, height: height}
    else
      jpeg_dimensions(buffer, i + 2 + segment_length)
    end
  end

  defp jpeg_dimensions(_buffer, _i), do: raise("Could not parse JPEG dimensions")
end
