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
  alias PlaywrightEx.Video

  # it.skip(({ video }) => video === 'on', 'conflicts with built-in video recording');  -- the runner records no video

  defp find_videos(video_dir) do
    for file <- File.ls!(video_dir), String.ends_with?(file, "webm"), do: Path.join(video_dir, file)
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

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should capture static page"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should pad a short frame to the video size"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should continue recording main page after popup closes"

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

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should capture navigation"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should capture css transformation"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should work for popups"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should scale frames down to the requested size "

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should use viewport scaled down to fit into 800x800 as default size"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should be 800x450 by default"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should record video with the requested fps"

    @tag :tmp_dir
    test "should throw on invalid fps", %{browser: browser, tmp_dir: tmp_dir} do
      {:error, error} = Browser.new_context(browser, record_video: %{dir: tmp_dir, fps: 0})
      assert error.message =~ ~s("recordVideo.fps" must be a positive number, got 0)
    end

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should be 800x600 with null viewport"

    @tag skip: "not ported: launchPersistentContext"
    test "should capture static page in persistent context @smoke"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should emulate an iphone"

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

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should wait for video to finish if page was closed"

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

    @tag skip: "not ported: storageState"
    test "should not create video for internal pages"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should capture full viewport"

    @tag skip: "not ported: VideoPlayer (ffmpeg)"
    test "should capture full viewport on hidpi"

    @tag skip: "not ported: VideoPlayer (ffmpeg), JPEG decoding"
    test "should work with video+trace"
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
