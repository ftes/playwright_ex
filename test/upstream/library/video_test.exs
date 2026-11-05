defmodule PlaywrightEx.Library.VideoTest do
  @upstream "tests/library/video.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [ensure_some_frames: 1]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Api
  alias PlaywrightEx.Playwright
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.Tracing
  alias PlaywrightEx.Utils
  alias PlaywrightEx.Video
  alias PlaywrightEx.VideoPlayer

  @browser_name System.get_env("BROWSER", "chromium")
  @ffmpeg_skip VideoPlayer.skip_reason()

  # it.skip(({ video }) => video === 'on', 'conflicts with built-in video recording');  -- the runner records no video

  defp is_almost_red(%{r: r, g: g, b: b, alpha: alpha}), do: r > 185 and g < 70 and b < 70 and alpha == 255

  defp is_almost_black(%{r: r, g: g, b: b, alpha: alpha}), do: r < 70 and g < 70 and b < 70 and alpha == 255

  defp is_almost_gray(%{r: r, g: g, b: b, alpha: alpha}),
    do: r > 70 and r < 185 and g > 70 and g < 185 and b > 70 and b < 185 and alpha == 255

  defp find_pixel(pixels, pixel_predicate),
    do: Enum.find(for(<<r, g, b, alpha <- pixels>>, do: %{r: r, g: g, b: b, alpha: alpha}), pixel_predicate)

  defp every_pixel(pixels, pixel_predicate), do: !find_pixel(pixels, &(!pixel_predicate.(&1)))

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

  defp find_videos(video_dir) do
    for file <- File.ls!(video_dir), String.ends_with?(file, "webm"), do: Path.join(video_dir, file)
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

  describe "screencast" do
    # it.slow(); it.skip(({ mode }) => mode !== 'default', ...)  -- always default mode

    @tag :page
    test "should not have video by default", %{page: page} do
      assert Page.video(page) == nil
    end

    test "should not throw without recordVideo.dir", %{browser: browser} do
      context = Browser.new_context!(browser, record_video: %{})
      BrowserContext.close!(context)
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should capture static page", %{browser: browser, tmp_dir: tmp_dir} do
      # Firefox does not have a mobile variant and has a large minimum size (500 on windows and 450 elsewhere).
      size = if @browser_name == "firefox", do: %{width: 500, height: 400}, else: %{width: 320, height: 240}
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)

      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      expect_red_frames(video_file, size)
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should pad a short frame to the video size", %{browser: browser, tmp_dir: tmp_dir} do
      video_size = %{width: 800, height: 600}

      context =
        Browser.new_context!(browser,
          record_video: %{dir: tmp_dir, size: video_size},
          viewport: %{width: 800, height: 396}
        )

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      assert video_player.videoWidth == video_size.width
      assert video_player.videoHeight == video_size.height
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should continue recording main page after popup closes", %{browser: browser, tmp_dir: tmp_dir} do
      # Issue: https://github.com/microsoft/playwright/issues/30837
      # Firefox does not have a mobile variant and has a large minimum size (500 on windows and 450 elsewhere).
      size = if @browser_name == "firefox", do: %{width: 500, height: 400}, else: %{width: 320, height: 240}
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)
      Page.set_content!(page, "<a target=_blank href=\"about:blank\">clickme</a>")
      popup = Page.expect_popup!(page, fn -> Page.click!(page, "a") end)
      Page.close!(popup)

      Page.evaluate!(page, """
      () => {
        document.body.textContent = ''; // remove link
        document.body.style.backgroundColor = 'red';
      }
      """)

      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      expect_red_frames(video_file, size)
    end

    @tag :tmp_dir
    test "should expose video path", %{browser: browser, tmp_dir: videos_path} do
      size = %{width: 320, height: 240}
      context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)
      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      path = Video.path!(Page.video(page))
      assert path =~ videos_path
      BrowserContext.close!(context)
      assert File.exists?(path)
    end

    @tag :tmp_dir
    test "should delete video", %{browser: browser, tmp_dir: videos_path} do
      size = %{width: 320, height: 240}
      context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)
      delete_promise = Task.async(fn -> Video.delete!(Page.video(page)) end)
      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_path = Video.path!(Page.video(page))
      Task.await(delete_promise)
      refute File.exists?(video_path)
    end

    @tag :tmp_dir
    test "should expose video path blank page", %{browser: browser, tmp_dir: videos_path} do
      size = %{width: 320, height: 240}
      context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)
      path = Video.path!(Page.video(page))
      assert path =~ videos_path
      BrowserContext.close!(context)
      assert File.exists?(path)
    end

    @tag :tmp_dir
    test "should work with weird screen resolution", %{browser: browser, tmp_dir: videos_path} do
      size = %{width: 1904, height: 609}
      context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)
      path = Video.path!(Page.video(page))
      assert path =~ videos_path
      BrowserContext.close!(context)
      assert File.exists?(path)
    end

    @tag :tmp_dir
    test "should work with relative path for recordVideo.dir", %{browser: browser, tmp_dir: tmp_dir} do
      videos_path = Path.relative_to_cwd(tmp_dir)
      size = %{width: 320, height: 240}
      context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)
      video_path = Video.path!(Page.video(page))
      BrowserContext.close!(context)
      assert File.exists?(video_path)
    end

    @tag :tmp_dir
    test "should expose video path blank popup", %{browser: browser, tmp_dir: videos_path} do
      size = %{width: 320, height: 240}
      context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)
      popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, ~s{window.open("about:blank")}) end)
      path = Video.path!(Page.video(popup))
      assert path =~ videos_path
      BrowserContext.close!(context)
      assert File.exists?(path)
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should capture navigation", %{browser: browser, server: server, tmp_dir: tmp_dir} do
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, size: %{width: 1280, height: 720}})
      page = BrowserContext.new_page!(context)

      Page.goto!(page, server.prefix <> "/background-color.html#rgb(0,0,0)")
      ensure_some_frames(page)
      Page.goto!(page, server.cross_process_prefix <> "/background-color.html#rgb(100,100,100)")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      duration = video_player.duration
      assert duration > 0

      # Find a frame with all almost-black pixels.
      frame = VideoPlayer.find_frame(video_player, &every_pixel(&1, fn pixel -> is_almost_black(pixel) end))
      assert frame != nil

      pixels = VideoPlayer.seek_last_frame(video_player).data
      expect_all(pixels, &is_almost_gray/1)
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should capture css transformation", %{browser: browser, server: server, tmp_dir: tmp_dir} do
      # it.fixme(!headless, ...): headless; it.fixme(browserName === 'webkit' && platform === 'win32')  -- not run on Windows
      size = %{width: 600, height: 400}
      # Set viewport equal to screencast frame size to avoid scaling.
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, size: size}, viewport: size)
      page = BrowserContext.new_page!(context)

      Page.goto!(page, server.prefix <> "/rotate-z.html")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      duration = video_player.duration
      assert duration > 0

      pixels = VideoPlayer.seek_last_frame(video_player, %{x: 95, y: 45}).data
      expect_all(pixels, &is_almost_red/1)
    end

    @tag skip:
           @ffmpeg_skip ||
             if(@browser_name == "firefox", do: "upstream fixme: https://github.com/microsoft/playwright/issues/14557")
    @tag :tmp_dir
    test "should work for popups", %{browser: browser, server: server, tmp_dir: videos_path} do
      # it.fixme(browserName === 'firefox' && !isBidi, ...): firefox is never BiDi here
      size = %{width: 600, height: 400}
      context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)

      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      popup = Page.expect_popup!(page, fn -> Page.evaluate!(page, "() => { window.open('about:blank'); }") end)
      Page.evaluate!(popup, "() => document.body.style.backgroundColor = 'red'")
      Task.await_many([Task.async(fn -> ensure_some_frames(page) end), Task.async(fn -> ensure_some_frames(popup) end)])
      BrowserContext.close!(context)

      page_video_file = Video.path!(Page.video(page))
      popup_video_file = Video.path!(Page.video(popup))
      assert page_video_file != popup_video_file
      expect_red_frames(popup_video_file, size)

      video_files = find_videos(videos_path)
      assert length(video_files) == 2
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should scale frames down to the requested size ", %{browser: browser, server: server, tmp_dir: tmp_dir} do
      # it.fixme(!headless, ...): headless; it.fixme(browserName === 'chromium' && !isHeadlessShell, ...): headless chromium is the headless shell
      context =
        Browser.new_context!(browser,
          # Set size to 1/2 of the viewport.
          record_video: %{dir: tmp_dir, size: %{width: 320, height: 240}},
          viewport: %{width: 640, height: 480}
        )

      page = BrowserContext.new_page!(context)

      Page.goto!(page, server.prefix <> "/checkerboard.html")
      # Update the picture to ensure enough frames are generated.
      Page.eval_on_selector!(
        page,
        ".container",
        "container => { container.firstElementChild.classList.remove('red'); }"
      )

      ensure_some_frames(page)
      Page.eval_on_selector!(page, ".container", "container => { container.firstElementChild.classList.add('red'); }")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      duration = video_player.duration
      assert duration > 0

      pixels = VideoPlayer.seek_last_frame(video_player, %{x: 10, y: 10}).data
      expect_all(pixels, &is_almost_red/1)
      pixels = VideoPlayer.seek_last_frame(video_player, %{x: 300, y: 10}).data
      expect_all(pixels, &is_almost_gray/1)
      pixels = VideoPlayer.seek_last_frame(video_player, %{x: 10, y: 200}).data
      expect_all(pixels, &is_almost_gray/1)
      pixels = VideoPlayer.seek_last_frame(video_player, %{x: 300, y: 200}).data
      expect_all(pixels, &is_almost_red/1)
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should use viewport scaled down to fit into 800x800 as default size", %{browser: browser, tmp_dir: tmp_dir} do
      size = %{width: 1600, height: 1200}
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir}, viewport: size)

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      assert video_player.videoWidth == 800
      assert video_player.videoHeight == 600
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should be 800x450 by default", %{browser: browser, tmp_dir: tmp_dir} do
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir})

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      assert video_player.videoWidth == 800
      assert video_player.videoHeight == 450
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should record video with the requested fps", %{browser: browser, tmp_dir: tmp_dir} do
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, fps: 60})

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_player = VideoPlayer.new(Video.path!(Page.video(page)))
      assert video_player.fps == 60
    end

    @tag :tmp_dir
    test "should throw on invalid fps", %{browser: browser, tmp_dir: tmp_dir} do
      {:error, error} = Browser.new_context(browser, record_video: %{dir: tmp_dir, fps: 0})
      assert error.message =~ ~s("recordVideo.fps" must be a positive number, got 0)
    end

    @tag skip: @ffmpeg_skip || if(@browser_name == "firefox", do: "upstream fixme: Fails in headless on bots")
    @tag :tmp_dir
    test "should be 800x600 with null viewport", %{browser: browser, tmp_dir: tmp_dir} do
      # it.fixme(browserName === 'firefox' && headless && !isBidi, ...): headless, firefox is never BiDi here
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir}, viewport: :null)

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      assert video_player.videoWidth == 800
      assert video_player.videoHeight == 600
    end

    @tag skip:
           @ffmpeg_skip ||
             if(
               @browser_name == "webkit" and match?({:unix, :darwin}, :os.type()) and
                 :erlang.system_info(:system_architecture) |> to_string() |> String.starts_with?("aarch64"),
               do:
                 "upstream skip: Is only failing on self-hosted github actions runner on M1 mac; not reproducible locally"
             )
    @tag :tmp_dir
    test "should capture static page in persistent context @smoke", %{
      launch_persistent: launch_persistent,
      tmp_dir: tmp_dir
    } do
      size = %{width: 600, height: 400}
      %{context: context, page: page} = launch_persistent.(record_video: %{dir: tmp_dir, size: size}, viewport: size)

      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      duration = video_player.duration
      assert duration > 0

      assert video_player.videoWidth == 600
      assert video_player.videoHeight == 400

      pixels = VideoPlayer.seek_last_frame(video_player).data
      expect_all(pixels, &is_almost_red/1)
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should emulate an iphone", %{context_factory: context_factory, playwright: playwright, tmp_dir: tmp_dir} do
      device = Playwright.devices(playwright)["iPhone 6"]
      context = context_factory.(Map.to_list(Map.put(device, :record_video, %{dir: tmp_dir})))

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      video_player = VideoPlayer.new(video_file)
      assert video_player.videoWidth == 374
      assert video_player.videoHeight == 666
    end

    @tag :tmp_dir
    test "should throw on browser close", %{browser_type: browser_type, tmp_dir: tmp_dir} do
      size = %{width: 320, height: 240}
      browser = BrowserType.launch!(browser_type)
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, size: size}, viewport: size)

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      Browser.close!(browser)

      file = Path.join(tmp_dir, "saved-video-")
      {:error, save_result} = Video.save_as(Page.video(page), file)
      assert save_result.message =~ "browser has been closed"
    end

    @tag :tmp_dir
    test "should throw if browser dies", %{browser_type: browser_type, tmp_dir: tmp_dir} do
      size = %{width: 320, height: 240}
      browser = BrowserType.launch!(browser_type)
      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, size: size}, viewport: size)

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      # (browser as any)._channel.killForTests()
      Api.call(nil, browser, fn -> ChannelOwner.channel_call(browser, :killForTests, %{}) end)

      file = Path.join(tmp_dir, "saved-video-")
      {:error, save_result} = Video.save_as(Page.video(page), file)
      assert save_result.message =~ "rowser has been closed"
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should wait for video to finish if page was closed", %{browser_type: browser_type, tmp_dir: video_dir} do
      size = %{width: 320, height: 240}
      browser = BrowserType.launch!(browser_type)

      context = Browser.new_context!(browser, record_video: %{dir: video_dir, size: size}, viewport: size)

      page = BrowserContext.new_page!(context)
      ensure_some_frames(page)
      Page.close!(page)
      BrowserContext.close!(context)
      Browser.close!(browser)

      video_files = find_videos(video_dir)
      assert length(video_files) == 1
      video_player = VideoPlayer.new(hd(video_files))
      assert video_player.videoWidth == 320
      assert video_player.videoHeight == 240
    end

    @tag :tmp_dir
    test "should close ffmpeg even if there were no frames", %{browser_type: browser_type, tmp_dir: video_dir} do
      size = %{width: 320, height: 240}
      browser = BrowserType.launch!(browser_type)
      context = Browser.new_context!(browser, record_video: %{dir: video_dir, size: size}, viewport: size)

      page1 = BrowserContext.new_page!(context)
      Page.close!(page1)

      page2 = BrowserContext.new_page!(context)
      Page.close!(page2)

      BrowserContext.close!(context)
      Browser.close!(browser)

      video_files = find_videos(video_dir)
      assert length(video_files) == 2
    end

    @tag :tmp_dir
    test "should not create video for internal pages", %{browser: browser, server: server, tmp_dir: video_dir} do
      TestServer.set_route(server, "/empty.html", fn conn ->
        conn |> Plug.Conn.put_resp_header("set-cookie", "name=value") |> Plug.Conn.send_resp(200, "")
      end)

      context = Browser.new_context!(browser, record_video: %{dir: video_dir})

      page = BrowserContext.new_page!(context)
      Page.goto!(page, server.empty_page)
      ensure_some_frames(page)

      cookies = BrowserContext.cookies!(context)
      assert length(cookies) == 1
      BrowserContext.storage_state!(context)
      BrowserContext.close!(context)

      files = File.ls!(video_dir)
      assert length(files) == 1
    end

    @tag skip:
           @ffmpeg_skip ||
             if(@browser_name == "firefox" and match?({:win32, _}, :os.type()),
               do: "upstream fixme: https://github.com/microsoft/playwright/issues/14405"
             )
    @tag :tmp_dir
    test "should capture full viewport", %{browser_type: browser_type, tmp_dir: video_dir} do
      # Issue: https://github.com/microsoft/playwright/issues/22411
      # it.fixme(browserName === 'chromium' && !isHeadlessShell, ...): headless chromium is the headless shell
      size = %{width: 600, height: 400}
      browser = BrowserType.launch!(browser_type)

      context = Browser.new_context!(browser, viewport: size, record_video: %{dir: video_dir, size: size})

      page = BrowserContext.new_page!(context)

      Page.set_content!(
        page,
        "<div style='margin: 0; background: red; position: fixed; right:0; bottom:0; width: 30; height: 30;'></div>"
      )

      ensure_some_frames(page)
      Page.close!(page)
      BrowserContext.close!(context)
      Browser.close!(browser)

      video_files = find_videos(video_dir)
      assert length(video_files) == 1
      video_player = VideoPlayer.new(hd(video_files))
      assert video_player.videoWidth == size.width
      assert video_player.videoHeight == size.height

      # Bottom right corner should be part of the red border.
      # However, headed browsers on mac have rounded corners, so offset by 10.
      pixels = VideoPlayer.seek_last_frame(video_player, %{x: size.width - 20, y: size.height - 20}).data
      expect_all(pixels, &is_almost_red/1)
    end

    @tag skip:
           @ffmpeg_skip ||
             if(@browser_name == "firefox" and match?({:win32, _}, :os.type()),
               do: "upstream fixme: https://github.com/microsoft/playwright/issues/14405"
             )
    @tag :tmp_dir
    test "should capture full viewport on hidpi", %{browser_type: browser_type, tmp_dir: video_dir} do
      # Issue: https://github.com/microsoft/playwright/issues/22411
      # it.fixme(browserName === 'chromium' && !isHeadlessShell, ...): headless chromium is the headless shell
      # it.fixme(browserName === 'webkit' && !headless && ...): headless
      size = %{width: 600, height: 400}
      browser = BrowserType.launch!(browser_type)

      context =
        Browser.new_context!(browser,
          viewport: size,
          device_scale_factor: 3,
          record_video: %{dir: video_dir, size: size}
        )

      page = BrowserContext.new_page!(context)

      Page.set_content!(
        page,
        "<div style='margin: 0; background: red; position: fixed; right:0; bottom:0; width: 30; height: 30;'></div>"
      )

      ensure_some_frames(page)
      Page.close!(page)
      BrowserContext.close!(context)
      Browser.close!(browser)

      video_files = find_videos(video_dir)
      assert length(video_files) == 1
      video_player = VideoPlayer.new(hd(video_files))
      assert video_player.videoWidth == size.width
      assert video_player.videoHeight == size.height

      # Bottom right corner should be part of the red border.
      # However, headed browsers on mac have rounded corners, so offset by 10.
      pixels = VideoPlayer.seek_last_frame(video_player, %{x: size.width - 20, y: size.height - 20}).data
      expect_all(pixels, &is_almost_red/1)
    end

    @tag skip: @ffmpeg_skip
    @tag :tmp_dir
    test "should work with video+trace", %{browser: browser, tmp_dir: tmp_dir} do
      # it.skip(trace === 'on'): no runner trace; it.fixme(!headless, ...): headless;
      # it.fixme(browserName === 'chromium' && !isHeadlessShell, ...): headless chromium is the headless shell
      size = %{width: 500, height: 400}
      trace_file = Path.join(tmp_dir, "trace.zip")

      context = Browser.new_context!(browser, record_video: %{dir: tmp_dir, size: size}, viewport: size)
      Tracing.start!(BrowserContext.tracing(context), screenshots: true)
      page = BrowserContext.new_page!(context)

      Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
      ensure_some_frames(page)
      Tracing.stop!(BrowserContext.tracing(context), path: trace_file)
      BrowserContext.close!(context)

      video_file = Video.path!(Page.video(page))
      expect_red_frames(video_file, size)

      %{events: events, resources: resources} = Utils.parse_trace_raw(trace_file, page)
      frame = events |> Enum.filter(&(&1["type"] == "screencast-frame")) |> List.last()
      buffer = resources[frame["file"]]
      image = VideoPlayer.decode_jpeg(buffer)
      assert image.width == size.width
      assert image.height == size.height
      # Center should be red.
      offset = div(size.width * size.height, 2) * 4 + div(size.width * 4, 2)
      <<_::binary-size(^offset), r, g, b, alpha, _::binary>> = image.data
      assert is_almost_red(%{r: r, g: g, b: b, alpha: alpha}) == true
    end
  end

  @tag :tmp_dir
  test "should saveAs video", %{browser: browser, tmp_dir: videos_path} do
    size = %{width: 320, height: 240}
    context = Browser.new_context!(browser, record_video: %{dir: videos_path, size: size}, viewport: size)
    page = BrowserContext.new_page!(context)
    Page.evaluate!(page, "() => document.body.style.backgroundColor = 'red'")
    ensure_some_frames(page)
    BrowserContext.close!(context)

    save_as_path = Path.join(videos_path, "my-video.webm")
    Video.save_as!(Page.video(page), save_as_path)
    assert File.exists?(save_as_path)
  end
end
