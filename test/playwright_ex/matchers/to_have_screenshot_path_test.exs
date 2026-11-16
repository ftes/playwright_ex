defmodule PlaywrightEx.Matchers.ToHaveScreenshotPathTest do
  # Not mirrored from upstream: its snapshots are resolved by the test runner, here by `path:`.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  import ExUnit.CaptureIO

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.TestInfo

  @moduletag :page
  @moduletag :tmp_dir

  test "outside a test, announces a missing snapshot it writes", %{page: page, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "home.png")
    Page.set_content!(page, "<h1>title</h1>")

    outside_test(fn ->
      assert capture_io(fn -> assert :ok = Expect.to_have_screenshot(page, path: path) end) =~ "writing actual"
      assert File.exists?(path)
      assert capture_io(fn -> assert :ok = Expect.to_have_screenshot(page, path: path) end) == ""
    end)
  end

  test "in a test, a missing snapshot it writes is the test's error", %{page: page, tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "home.png")
    Page.set_content!(page, "<h1>title</h1>")

    assert capture_io(fn -> assert :ok = Expect.to_have_screenshot(page, path: path) end) == ""
    assert [{:error, %RuntimeError{message: message}, _}] = TestInfo.take_errors(self())
    assert message == "A snapshot doesn't exist at #{path}, writing actual."
    assert File.exists?(path)
  end

  # Runs `fun` in a process of no test.
  defp outside_test(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      fun.()
    end)
    |> Task.await(:infinity)
  end
end
