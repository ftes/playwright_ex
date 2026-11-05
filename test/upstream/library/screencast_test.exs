defmodule PlaywrightEx.Library.ScreencastTest do
  @upstream "tests/library/screencast.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [ensure_some_frames: 1]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Screencast
  alias PlaywrightEx.Utils
  alias PlaywrightEx.VideoPlayer

  @browser_name System.get_env("BROWSER", "chromium")
  @ffmpeg_skip VideoPlayer.skip_reason()

  # config/errors.ts
  @k_target_closed_error_message "Target page, context or browser has been closed"

  # test.skip(mode !== 'default'), test.skip(video === 'on'), test.slow()  -- always default mode, no runner video

  # Date.now()
  defp now, do: System.os_time(:millisecond)

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

    assert frames.() != []

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

  test "applies backpressure while async onFrame callback is pending", %{browser: browser, server: server} do
    context = Browser.new_context!(browser, viewport: %{width: 500, height: 400})
    page = BrowserContext.new_page!(context)

    # `new Promise(f => releaseCallback = f)`: a runtime promise (the public API creates none).
    callback_done = EventLoop.with_baton(page.loop, fn -> Runtime.Promise.new() end)
    {:ok, state} = Agent.start_link(fn -> %{frame_count: 0, last_frame_timestamp: 0} end)
    me = self()

    Screencast.start!(Page.screencast(page),
      on_frame: fn _ ->
        Agent.update(state, &%{&1 | frame_count: &1.frame_count + 1, last_frame_timestamp: now()})
        send(me, :first_frame)
        PlaywrightEx.Promise.await!(callback_done)
      end
    )

    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => {
      const animate = () => {
        document.body.style.backgroundColor = document.body.style.backgroundColor === 'red' ? 'blue' : 'red';
        requestAnimationFrame(animate);
      };
      requestAnimationFrame(animate);
    }
    """)

    assert_receive :first_frame, 5000
    Utils.poll(fn -> now() - Agent.get(state, & &1.last_frame_timestamp) end, &assert(&1 > 1000), timeout: 30_000)

    frames_while_blocked = Agent.get(state, & &1.frame_count)
    ensure_some_frames(page)
    assert Agent.get(state, & &1.frame_count) == frames_while_blocked

    Runtime.Promise.resolve(callback_done, nil)

    Utils.poll(
      fn ->
        Page.evaluate!(page, """
        () => {
          document.body.style.backgroundColor = document.body.style.backgroundColor === 'red' ? 'blue' : 'red';
        }
        """)

        ensure_some_frames(page)
        Agent.get(state, & &1.frame_count)
      end,
      &assert(&1 > frames_while_blocked),
      timeout: 30_000
    )

    Screencast.stop!(Page.screencast(page))
    BrowserContext.close!(context)
  end

  @tag skip:
         if(@browser_name == "webkit" and match?({:unix, :darwin}, :os.type()),
           do: "env: Mac WebKit (macOS 26) reports a 901x361 viewport for 1000x400 (upstream client too)"
         )
  test "onFrame receives viewport size", %{browser: browser, server: server} do
    # test.skip(trace === 'on', ...): no trace; test.fixme(browserName === 'firefox' && isMac && !headless, ...): headless
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

    assert frames.() != []

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

  @tag skip: @ffmpeg_skip
  @tag :tmp_dir
  test "start should record video with the requested fps", %{browser: browser, tmp_dir: tmp_dir} do
    context = Browser.new_context!(browser)
    page = BrowserContext.new_page!(context)
    video_path = Path.join(tmp_dir, "video.webm")
    Screencast.start!(Page.screencast(page), path: video_path, fps: 60)
    ensure_some_frames(page)
    Screencast.stop!(Page.screencast(page))
    assert VideoPlayer.new(video_path).fps == 60
    BrowserContext.close!(context)
  end

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

  @tag skip: @ffmpeg_skip
  @tag :tmp_dir
  test "empty video", %{browser: browser, tmp_dir: tmp_dir} do
    size = %{width: 800, height: 800}
    context = Browser.new_context!(browser, viewport: size)
    page = BrowserContext.new_page!(context)
    video_path = Path.join(tmp_dir, "empty-video.webm")
    Screencast.start!(Page.screencast(page), path: video_path, size: size)
    Screencast.stop!(Page.screencast(page))
    BrowserContext.close!(context)
    expect_frames(video_path, size, &is_almost_white/1)
  end

  @tag skip: @ffmpeg_skip
  @tag :tmp_dir
  test "start dispose stops recording", %{browser: browser, tmp_dir: tmp_dir} do
    size = %{width: 800, height: 800}
    context = Browser.new_context!(browser, viewport: size)
    page = BrowserContext.new_page!(context)
    video_path = Path.join(tmp_dir, "dispose-video.webm")
    disposable = Screencast.start!(Page.screencast(page), path: video_path, size: size)
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
    ensure_some_frames(page)
    Disposable.dispose!(disposable)
    expect_red_frames(video_path, size)
    BrowserContext.close!(context)
  end

  defp is_almost_white(%{r: r, g: g, b: b, alpha: alpha}), do: r > 185 and g > 185 and b > 185 and alpha == 255

  defp is_almost_red(%{r: r, g: g, b: b, alpha: alpha}), do: r > 185 and g < 70 and b < 70 and alpha == 255

  defp find_pixel(pixels, pixel_predicate),
    do: Enum.find(for(<<r, g, b, alpha <- pixels>>, do: %{r: r, g: g, b: b, alpha: alpha}), pixel_predicate)

  defp expect_all(pixels, pixel_predicate) do
    if bad_pixel = find_pixel(pixels, &(!pixel_predicate.(&1))) do
      rgba = Enum.join([bad_pixel.r, bad_pixel.g, bad_pixel.b, bad_pixel.alpha], ", ")
      {:name, name} = Function.info(pixel_predicate, :name)

      flunk(
        Enum.join(
          [
            "Expected all pixels to satisfy #{name}, found bad pixel (#{rgba})",
            "Actual pixels=[#{Enum.join(:binary.bin_to_list(pixels), ",")}]"
          ],
          "\n"
        )
      )
    end
  end

  defp expect_red_frames(video_file, size), do: expect_frames(video_file, size, &is_almost_red/1)

  defp expect_frames(video_file, size, pixel_predicate) do
    video_player = VideoPlayer.new(video_file)
    duration = video_player.duration
    assert duration > 0

    assert video_player.videoWidth == size.width
    assert video_player.videoHeight == size.height

    pixels = VideoPlayer.seek_last_frame(video_player).data
    expect_all(pixels, pixel_predicate)

    pixels = VideoPlayer.seek_last_frame(video_player, %{x: size.width - 20, y: 10}).data
    expect_all(pixels, pixel_predicate)
  end

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
