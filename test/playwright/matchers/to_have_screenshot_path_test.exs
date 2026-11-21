defmodule Playwright.Matchers.ToHaveScreenshotPathTest do
  # Not mirrored from upstream: its snapshots are resolved by the test runner, here by `path:`.
  @upstream nil
  use Playwright.UpstreamCase, async: true

  import ExUnit.CaptureIO

  alias Playwright.Expect
  alias Playwright.Page
  alias Playwright.Test.TestInfo

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

defmodule Playwright.Matchers.ToHaveScreenshotTimeoutTest do
  # Not mirrored from upstream. Not async: it sets the expect config, which is global as in JS.
  @upstream nil
  use Playwright.UpstreamCase, async: false

  alias Playwright.Expect
  alias Playwright.Matchers.Expect, as: ExpectConfig
  alias Playwright.Page

  @moduletag :page
  @moduletag :tmp_dir

  setup do
    on_exit(fn -> :persistent_term.erase({ExpectConfig, :expect_config}) end)
  end

  # Upstream's `helper.options.timeout ?? this.timeout`: the config's `toHaveScreenshot.timeout`
  # over the expect timeout, a call's `timeout` over both.
  test "the config's to_have_screenshot timeout beats the expect timeout, a call's beats it", %{
    page: page,
    tmp_dir: tmp_dir
  } do
    ExpectConfig.set_expect_config(
      ExpectConfig.app_env_expect_config(timeout: 20_000, to_have_screenshot: [timeout: 300])
    )

    path = Path.join(tmp_dir, "home.png")
    Page.set_content!(page, "<h1>before</h1>")
    assert :ok = Expect.to_have_screenshot(page, path: path, timeout: 5_000)
    Playwright.Test.TestInfo.take_errors(self())
    Page.set_content!(page, "<h1>after, longer</h1>")

    assert {:error, error} = Expect.to_have_screenshot(page, path: path)
    assert Exception.message(error) =~ ~s(Expect "toHaveScreenshot" with timeout 300ms)

    assert {:error, error} = Expect.to_have_screenshot(page, path: path, timeout: 200)
    assert Exception.message(error) =~ ~s(Expect "toHaveScreenshot" with timeout 200ms)
  end
end
