defmodule PlaywrightEx.Matchers.ToMatchAriaSnapshotPathTest do
  # Not mirrored from upstream: its file snapshots are resolved by the test runner, here by `path:`.
  @upstream nil
  # The expect configuration is global.
  use PlaywrightEx.UpstreamCase, async: false

  import ExUnit.CaptureIO

  alias PlaywrightEx.Expect
  alias PlaywrightEx.ExpectError
  alias PlaywrightEx.Page

  @moduletag :page
  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Application.get_env(:playwright_ex, :expect)
    on_exit(fn -> Application.put_env(:playwright_ex, :expect, previous) end)
    [path: Path.join([tmp_dir, "nested", "body.aria.yml"])]
  end

  defp update_snapshots(value) do
    previous = Application.get_env(:playwright_ex, :expect)
    Application.put_env(:playwright_ex, :expect, Keyword.put(previous, :update_snapshots, value))
  end

  defp write(path, snapshot) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, snapshot)
  end

  test "writes a missing snapshot and compares against it afterwards", %{page: page, path: path} do
    Page.set_content!(page, "<h1>title</h1>")

    assert capture_io(fn -> assert :ok = Expect.to_match_aria_snapshot(page, path: path) end) =~ "writing actual"
    assert File.read!(path) == ~s(- heading "title" [level=1])
    assert capture_io(fn -> assert :ok = Expect.to_match_aria_snapshot(page, path: path) end) == ""

    Page.set_content!(page, "<h1>other</h1>")
    assert {:error, %ExpectError{}} = Expect.to_match_aria_snapshot(page, path: path, timeout: 100)
    assert File.read!(path) == ~s(- heading "title" [level=1])
  end

  test "reads the expected snapshot from the file", %{page: page, path: path} do
    write(path, ~s(- heading "title"\n))
    Page.set_content!(page, "<h1>title</h1>")

    assert :ok = Expect.to_match_aria_snapshot(page, path: path)
    assert File.read!(path) == ~s(- heading "title"\n)
  end

  test "works on a locator, with a path relative to the working directory", %{page: page, tmp_dir: tmp_dir} do
    path = tmp_dir |> Path.join("relative.aria.yml") |> Path.relative_to_cwd()
    write(path, ~s(- heading "title"))
    Page.set_content!(page, "<main><h1>title</h1></main>")

    assert :ok = page |> Page.locator("main") |> Expect.to_match_aria_snapshot(path: path)
  end

  test ":none does not write a snapshot", %{page: page, path: path} do
    update_snapshots(:none)
    write(path, ~s(- heading "other"))
    Page.set_content!(page, "<h1>title</h1>")

    assert {:error, %ExpectError{}} = Expect.to_match_aria_snapshot(page, path: path, timeout: 100)
    assert File.read!(path) == ~s(- heading "other")
  end

  test ":none fails on a missing snapshot", %{page: page, path: path} do
    update_snapshots(:none)
    Page.set_content!(page, "<h1>title</h1>")

    assert {:error, %ExpectError{}} = Expect.to_match_aria_snapshot(page, path: path, timeout: 100)
    refute File.exists?(path)
  end

  for mode <- [:changed, :all] do
    test "#{inspect(mode)} writes a missing snapshot", %{page: page, path: path} do
      update_snapshots(unquote(mode))
      Page.set_content!(page, "<h1>title</h1>")

      assert capture_io(fn -> assert :ok = Expect.to_match_aria_snapshot(page, path: path, timeout: 100) end) =~
               "A snapshot is generated at"

      assert File.read!(path) == ~s(- heading "title" [level=1])
    end
  end

  test ":missing writes a missing snapshot and keeps a different one", %{page: page, path: path} do
    update_snapshots(:missing)
    Page.set_content!(page, "<h1>title</h1>")

    assert capture_io(fn -> assert :ok = Expect.to_match_aria_snapshot(page, path: path) end) =~ "writing actual"
    assert File.read!(path) == ~s(- heading "title" [level=1])

    write(path, ~s(- heading "other"))
    assert {:error, %ExpectError{}} = Expect.to_match_aria_snapshot(page, path: path, timeout: 100)
    assert File.read!(path) == ~s(- heading "other")
  end

  test ":changed rewrites a different snapshot only", %{page: page, path: path} do
    update_snapshots(:changed)
    write(path, ~s(- heading "title"))
    Page.set_content!(page, "<h1>title</h1>")

    assert :ok = Expect.to_match_aria_snapshot(page, path: path)
    assert File.read!(path) == ~s(- heading "title")

    write(path, ~s(- heading "other"))

    assert capture_io(fn -> assert :ok = Expect.to_match_aria_snapshot(page, path: path, timeout: 100) end) =~
             "A snapshot is generated at"

    assert File.read!(path) == ~s(- heading "title" [level=1])
  end

  test ":all rewrites a matching snapshot", %{page: page, path: path} do
    update_snapshots(:all)
    write(path, ~s(- heading "title"))
    Page.set_content!(page, "<h1>title</h1>")

    capture_io(fn -> assert :ok = Expect.to_match_aria_snapshot(page, path: path, timeout: 100) end)
    assert File.read!(path) == ~s(- heading "title" [level=1])
  end

  test "a negated matcher does not write a missing snapshot", %{page: page, path: path} do
    Page.set_content!(page, "<h1>title</h1>")

    assert {:error, %ExpectError{message: message}} =
             page |> Expect.not_() |> Expect.to_match_aria_snapshot(path: path)

    assert message =~ ~s(Matchers using ".not" can't generate new baselines)
    refute File.exists?(path)
  end

  test "a non-string expected with a path is rejected, not dropped", %{page: page, path: path} do
    assert {:error, error} = Expect.to_match_aria_snapshot(page, ~r/title/, path: path, timeout: 100)
    assert Exception.message(error) =~ "not both"
  end

  test "takes the expected snapshot or the path, not both or neither", %{page: page, path: path} do
    assert {:error, error} = Expect.to_match_aria_snapshot(page, ~s(- heading "title"), path: path)
    assert Exception.message(error) =~ "not both"

    assert {:error, error} = Expect.to_match_aria_snapshot(page)
    assert Exception.message(error) =~ "requires the expected snapshot or the path option"
  end
end
