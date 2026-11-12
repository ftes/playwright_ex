defmodule PlaywrightEx.Test.SnapshotsTest do
  # Snapshot names of `PlaywrightEx.Test` tests (upstream's `testInfo._resolveSnapshotPaths`),
  # their outputs in the test's output dir, and a written snapshot as the test's error. How the
  # errors fail a test: `PlaywrightEx.Test.EndToEndTest`.
  # `config :playwright_ex, :test` is global.
  use ExUnit.Case, async: false
  use PlaywrightEx.Test

  import ExUnit.CaptureIO

  alias PlaywrightEx.Expect
  alias PlaywrightEx.ExpectError
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Pool
  alias PlaywrightEx.Test.Recorder
  alias PlaywrightEx.Test.TestInfo

  @moduletag :tmp_dir

  setup_all :browser
  setup [:new_context, :new_page]

  setup %{tmp_dir: tmp_dir} do
    put_config(snapshot_dir: tmp_dir)
    [snapshots: Path.join(tmp_dir, "playwright_ex/test/snapshots_test.exs-snapshots"), platform: platform()]
  end

  defp put_config(config) do
    previous = Application.get_env(:playwright_ex, :test)
    Application.put_env(:playwright_ex, :test, Keyword.merge(previous, config))
    on_exit(fn -> Application.put_env(:playwright_ex, :test, previous) end)
  end

  defp platform do
    case :os.type() do
      {:win32, _} -> "win32"
      {_family, name} -> Atom.to_string(name)
    end
  end

  # Runs `fun` in a process of no test.
  defp outside_test(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      fun.()
    end)
    |> Task.await(:infinity)
  end

  test "upstream's default templates", %{snapshots: snapshots, platform: platform} = ctx do
    assert snapshot_path(ctx, "home.png", kind: :screenshot) == Path.join(snapshots, "home-#{platform}.png")
    assert snapshot_path(ctx, "home.png") == Path.join(snapshots, "home-#{platform}.png")
    assert snapshot_path(ctx, "body.aria.yml", kind: :aria) == Path.join(snapshots, "body.aria.yml")
    # A list is a path, not sanitized; a string is.
    assert snapshot_path(ctx, ["a b", "c.png"], kind: :screenshot) == Path.join(snapshots, "a b/c-#{platform}.png")
    assert snapshot_path(ctx, "a b/c?.png", kind: :screenshot) == Path.join(snapshots, "a-b-c--#{platform}.png")
    assert snapshot_path(ctx, ["one.png"], kind: :screenshot) == snapshot_path(ctx, "one.png", kind: :screenshot)

    assert_raise ArgumentError, ~r/unknown kind "other"/, fn -> snapshot_path(ctx, "a.png", kind: :other) end
  end

  test "the template's tokens", %{tmp_dir: tmp_dir, platform: platform} = ctx do
    put_config(
      snapshot_path_template:
        "{snapshotDir}/{testFileDir}/{testFileBaseName}/{testName}/{arg}{-projectName}{-platform}{ext}|" <>
          "{testDir}|{testFilePath}|{testFileName}"
    )

    assert snapshot_path(ctx, "home.png") ==
             Path.join(tmp_dir, "playwright_ex/test/snapshots_test/the-template-s-tokens/home-#{platform}.png") <>
               "|#{File.cwd!()}/test|playwright_ex/test/snapshots_test.exs|snapshots_test.exs"

    # The matcher's own template wins.
    previous = Application.get_env(:playwright_ex, :expect)
    on_exit(fn -> Application.put_env(:playwright_ex, :expect, previous) end)

    Application.put_env(
      :playwright_ex,
      :expect,
      Keyword.put(previous, :to_match_aria_snapshot, %{pathTemplate: "{arg}{ext}"})
    )

    assert snapshot_path(ctx, "body.aria.yml", kind: :aria) == Path.join(File.cwd!(), "body.aria.yml")
  end

  test "a test file outside test/ resolves against it, as upstream's path.relative(testDir, file)",
       %{tmp_dir: tmp_dir, platform: platform} = ctx do
    ctx = %{ctx | file: Path.join(File.cwd!(), "integration/checkout_test.exs")}

    assert snapshot_path(ctx, "home.png", kind: :screenshot) ==
             Path.expand("../integration/checkout_test.exs-snapshots/home-#{platform}.png", tmp_dir)
  end

  test "anonymous snapshots are numbered per test and kind, named ones per name", %{platform: platform} do
    this = TestInfo.current()
    resolve = &TestInfo._resolve_snapshot_paths(this, &1, &2, "updateSnapshotIndex")

    # The output path trimmed to 60 characters (`trimLongString`), then sanitized.
    assert %{absoluteSnapshotPath: first, relativeOutputPath: output} = resolve.("screenshot", nil)
    assert output =~ ~r/^anonymous-snapshots-are-nu-[0-9a-f]{5}-kind-named-ones-per-name-1\.png$/

    assert Path.basename(first) ==
             "anonymous-snapshots-are-numbered-per-test-and-kind-named-ones-per-name-1-#{platform}.png"

    assert Path.basename(resolve.("screenshot", nil).absoluteSnapshotPath) =~ ~r/name-2-#{platform}\.png$/
    assert Path.basename(resolve.("aria", nil).absoluteSnapshotPath) =~ ~r/name-1\.aria\.yml$/

    # The same file, other outputs.
    assert %{absoluteSnapshotPath: path, relativeOutputPath: "a.png"} = resolve.("screenshot", "a.png")
    assert %{absoluteSnapshotPath: ^path, relativeOutputPath: "a-1.png"} = resolve.("screenshot", "a.png")
  end

  test "a missing snapshot is written where its name resolves, as the test's error",
       %{page: page, snapshots: snapshots} = ctx do
    Page.set_content!(page, "<h1>title</h1>")

    assert :ok = Expect.to_match_aria_snapshot(page)
    assert :ok = Expect.to_have_screenshot(page, name: "home.png")

    aria = Path.join(snapshots, "a-missing-snapshot-is-written-where-its-name-resolves-as-the-test-s-error-1.aria.yml")
    assert File.read!(aria) == ~s(- heading "title" [level=1])
    screenshot = snapshot_path(ctx, "home.png", kind: :screenshot)
    assert File.exists?(screenshot)

    assert [
             {:error, %RuntimeError{message: first}, [{__MODULE__, _, _, _} | _]},
             {:error, %RuntimeError{message: second}, _}
           ] =
             TestInfo.take_errors(self())

    assert first == "A snapshot doesn't exist at #{Path.relative_to_cwd(aria)}, writing actual."
    assert second == "A snapshot doesn't exist at #{screenshot}, writing actual."
  end

  test "a snapshot's outputs go to the test's output dir", %{page: page} = ctx do
    Page.set_content!(page, "<h1>expected</h1>")
    path = snapshot_path(ctx, "home.png", kind: :screenshot)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Page.screenshot!(page))
    Page.set_content!(page, "<h1>actual</h1>")

    assert {:error, %ExpectError{matcherResult: result}} =
             Expect.to_have_screenshot(page, name: "home.png", timeout: 1000)

    dir = Path.expand(Recorder.output_dir(ctx))
    assert result.expected == path
    assert result.actual == Path.join(dir, "home-actual.png")
    assert result.diff == Path.join(dir, "home-diff.png")
    assert Enum.all?([result.actual, result.diff, Path.join(dir, "home-expected.png")], &File.exists?/1)
    assert result.message =~ "Snapshot: home.png"
  end

  test "outside a test: the path option, and a written snapshot is printed", %{page: page, tmp_dir: tmp_dir} do
    Page.set_content!(page, "<h1>title</h1>")
    path = Path.join(tmp_dir, "outside.png")

    outside_test(fn ->
      assert {:error, %RuntimeError{message: "toHaveScreenshot() requires the path option"}} =
               Expect.to_have_screenshot(page, name: "home.png")

      assert {:error, %RuntimeError{message: "toMatchAriaSnapshot() requires the expected snapshot or the path option"}} =
               Expect.to_match_aria_snapshot(page)

      assert capture_io(fn -> assert :ok = Expect.to_have_screenshot(page, path: path) end) =~ "writing actual"
    end)

    assert File.exists?(path)
    assert TestInfo.take_errors(self()) == []
  end

  test "an error recorded once the test ended is printed, and leaves no rows" do
    test_info = TestInfo.current()
    {pid, ref} = spawn_monitor(fn -> receive(do: (:exit -> exit(:shutdown))) end)
    this = %{test_info | test_pid: pid}
    :ets.insert(Pool.table(), {{:test_info, pid, :info}, this})
    Pool.watch(pid, Pool.start_module(), Pool.outside())
    error = &{:error, %RuntimeError{message: &1}, []}

    # The end of its body takes the errors; a later one (a Task of the test's) is printed.
    TestInfo._fail_with_error(this, error.("in the body"))
    assert TestInfo.finish(pid) == [error.("in the body")]
    assert capture_io(fn -> TestInfo._fail_with_error(this, error.("after the body")) end) == "after the body\n"

    # Its process ended: the same, also for a matcher's step and snapshot index.
    send(pid, :exit)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert Pool.result(pid, 5000) == {:failed, [Pool.outside()]}

    output =
      capture_io(fn ->
        TestInfo._fail_with_error(this, error.("after the process"))
        TestInfo._resolve_snapshot_paths(this, "screenshot", nil, "updateSnapshotIndex")
        step = TestInfo._add_step(this, %{category: "expect", title: "late"})
        TestInfo.step_complete(step, %{softError: %RuntimeError{message: "late step"}})
      end)

    assert output == "after the process\nlate step\n"
    assert :ets.match_object(Pool.table(), {{:test_info, pid, :_}, :_}) == []
  end

  test "the name or the path, not both", %{page: page} do
    assert {:error, error} = Expect.to_have_screenshot(page, name: "a.png", path: "a.png")
    assert Exception.message(error) =~ "not both"
    assert {:error, error} = Expect.to_match_aria_snapshot(page, name: "a.aria.yml", path: "a.aria.yml")
    assert Exception.message(error) =~ "not both"
    assert {:error, error} = Expect.to_match_aria_snapshot(page, "- heading", name: "a.aria.yml")
    assert Exception.message(error) =~ "not both"
  end
end
