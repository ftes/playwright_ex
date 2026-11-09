defmodule PlaywrightEx.Matchers.ToHaveScreenshotPathTest do
  # Not mirrored from upstream: its snapshots are resolved by the test runner, here by `path:`.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  import ExUnit.CaptureIO

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page

  @moduletag :page
  @moduletag :tmp_dir

  test "announces a missing snapshot it writes", %{page: page, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "home.png")
    Page.set_content!(page, "<h1>title</h1>")

    assert capture_io(fn -> assert :ok = Expect.to_have_screenshot(page, path: path) end) =~ "writing actual"
    assert File.exists?(path)
    assert capture_io(fn -> assert :ok = Expect.to_have_screenshot(page, path: path) end) == ""
  end
end
