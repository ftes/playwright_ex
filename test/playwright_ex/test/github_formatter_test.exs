defmodule PlaywrightEx.Test.GitHubFormatterTest do
  # Not async: it sets GITHUB_WORKSPACE and the formatter's config.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PlaywrightEx.Test.GitHubFormatter

  @file_path "test/playwright_ex/test/github_formatter_test.exs"
  @rule String.duplicate("─", 10)

  setup do
    workspace = System.get_env("GITHUB_WORKSPACE")
    System.delete_env("GITHUB_WORKSPACE")

    on_exit(fn ->
      if workspace, do: System.put_env("GITHUB_WORKSPACE", workspace), else: System.delete_env("GITHUB_WORKSPACE")
      Application.delete_env(:playwright_ex, GitHubFormatter)
    end)
  end

  test "a failed test: an error per failure, at its line in the test's file, escaped" do
    {failure, line} = {failure(fn -> raise "50% done,\r\nnext: x" end), __ENV__.line}
    test = test_struct("test checkout pays, once", describe: "checkout", state: {:failed, [failure]})

    [annotation] = run([{:test_finished, test}]) |> String.split("\n", trim: true) |> Enum.filter(&(&1 =~ "::error"))

    assert annotation =~
             "::error file=#{@file_path},title=#{@file_path}%3A10 › checkout › pays%2C once,line=#{line}::" <>
               "  1) #{@file_path}:10 › checkout › pays, once #{@rule}"

    assert annotation =~ "─%0A     ** (RuntimeError) 50%25 done,%0D%0A     next: x%0A     stacktrace:%0A"
    refute annotation =~ "\e["
  end

  test "a failure in a helper is at the helper's line; without a user frame, on the test's file" do
    [{helper, _}] =
      Code.compile_string(
        """
        defmodule PlaywrightEx.Test.GitHubFormatterTest.Helper do
          def check!, do: raise("oops")
        end
        """,
        "test/helpers/check_helper.ex"
      )

    test = test_struct("test fails", state: {:failed, [failure(fn -> helper.check!() end)]})

    assert run([{:test_finished, test}]) =~
             "\n::error file=test/helpers/check_helper.ex,title=#{@file_path}%3A10 › fails,line=2::"

    test =
      test_struct("test fails",
        state: {:failed, [{:exit, :boom, [{ExUnit.Runner, :exec_test, 2, file: ~c"lib/ex_unit/runner.ex", line: 1}]}]}
      )

    assert run([{:test_finished, test}]) =~
             "\n::error file=#{@file_path},title=#{@file_path}%3A10 › fails::  1) #{@file_path}:10 › fails "
  end

  test "a dependency's frames under the deps path are skipped, a path dependency's are the user's" do
    # As an app in a subdirectory of the workspace with a path dependency next to it.
    cwd = File.cwd!()
    workspace = Path.dirname(cwd)
    System.put_env("GITHUB_WORKSPACE", workspace)

    [{sibling, _}] =
      Code.compile_string(
        "defmodule GhfmtSibling.Expectation do\nend",
        Path.join(workspace, "ghfmt_sibling/lib/ghfmt_sibling/expectation.ex")
      )

    for {app, module} <- [ghfmt_dep: GhfmtDep.Expect, ghfmt_sibling: sibling] do
      :ok = :application.load({:application, app, [description: ~c"", vsn: ~c"1", modules: [module], applications: []]})
      on_exit(fn -> :application.unload(app) end)
    end

    deps = %{
      paths: %{ghfmt_dep: Path.join(cwd, "deps/ghfmt_dep"), ghfmt_sibling: Path.join(workspace, "ghfmt_sibling")},
      path: Path.join(cwd, "deps")
    }

    frame = fn module, file, line -> {module, :check!, 0, file: String.to_charlist(file), line: line} end
    user = frame.(__MODULE__, @file_path, 7)

    errors = fn stack ->
      run([{:test_finished, test_struct("test fails", state: {:failed, [{:error, %RuntimeError{}, stack}]})}],
        github_formatter_deps: deps
      )
    end

    in_workspace = Path.join(Path.basename(cwd), @file_path)

    assert errors.([frame.(GhfmtDep.Expect, "lib/expect.ex", 3), user]) =~
             "::error file=#{in_workspace},title=#{@file_path}%3A10 › fails,line=7::"

    assert errors.([frame.(sibling, "lib/ghfmt_sibling/expectation.ex", 5), user]) =~
             "::error file=ghfmt_sibling/lib/ghfmt_sibling/expectation.ex,title=#{@file_path}%3A10 › fails,line=5::"
  end

  test "a test name with a newline: the header is dropped from the failure text" do
    test = test_struct("test fails\nbadly", state: {:failed, [failure(fn -> raise "oops" end)]})
    output = run([{:test_finished, test}])
    assert output =~ "fails%0Abadly ─"
    assert output =~ "─%0A     ** (RuntimeError) oops%0A"
    refute output =~ "%0A     #{@file_path}:10%0A"
  end

  test "a parameterized module's parameters are the project" do
    test = %{
      test_struct("test fails", state: {:failed, [failure(fn -> raise "oops" end)]})
      | parameters: %{browser_name: :firefox}
    }

    output = run([{:test_finished, test}])
    assert output =~ ",title=[%25{browser_name%3A %3Afirefox}] › #{@file_path}%3A10 › fails,"
    assert output =~ "::  1) [%25{browser_name: :firefox}] › #{@file_path}:10 › fails ─"
    assert output =~ "─%0A     ** (RuntimeError) oops%0A"
  end

  test "the summary lists the failed tests and counts the others; a failed setup_all is an error" do
    failure = failure(fn -> raise "oops" end)
    module = %ExUnit.TestModule{name: Some.Module, file: __ENV__.file, state: {:failed, [failure]}}

    events = [
      {:test_finished, test_struct("test b", line: 20, state: {:failed, [failure]})},
      {:test_finished, test_struct("test a", line: 12, state: {:failed, [failure]})},
      {:test_finished, test_struct("test passes", line: 30)},
      {:test_finished, test_struct("test skipped", line: 31, state: {:skipped, "x"})},
      {:test_finished, test_struct("test excluded", line: 32, state: {:excluded, "x"})},
      {:test_finished, test_struct("test invalid", line: 33, state: {:invalid, module})},
      {:module_finished, module},
      {:suite_finished, %{run: 1_500_000, load: 200_000, async: 0}}
    ]

    output = run(events)
    lines = String.split(output, "\n", trim: true)
    # Each command is on a line of its own, also after a `.` of ExUnit.CLIFormatter's.
    assert String.starts_with?(output, "\n::")
    refute output =~ ~r/[^\n]::(error|warning|notice) /

    assert "::error ::Some.Module: failure on setup_all callback, all tests have been invalidated%0A" <>
             "     ** (RuntimeError) oops" <> _ = Enum.find(lines, &String.starts_with?(&1, "::error ::"))

    header = fn line, name ->
      "    #{@file_path}:#{line} › #{name} " <> rule(100 - 4 - String.length("#{@file_path}:#{line} › #{name} "))
    end

    assert List.last(lines) ==
             "::notice title=🎭 Playwright Run Summary::" <>
               Enum.join(
                 [
                   "  2 failed",
                   header.(12, "a"),
                   header.(20, "b"),
                   "  1 skipped",
                   "  1 did not run",
                   "  1 passed (1.7s)"
                 ],
                 "%0A"
               )
  end

  test "its config: report_slow_tests' max and threshold, non-negative numbers, or nil" do
    assert GitHubFormatter.config([]) == %{report_slow_tests: [max: 5, threshold: 300_000]}
    assert GitHubFormatter.config(report_slow_tests: nil) == %{report_slow_tests: nil}

    assert GitHubFormatter.config(report_slow_tests: %{threshold: 1, max: 0}) == %{
             report_slow_tests: [max: 0, threshold: 1]
           }

    assert_raise ArgumentError, ~r/unknown keys \[:slow\] .*, expected one of \[:report_slow_tests\]/, fn ->
      GitHubFormatter.config(slow: true)
    end

    assert_raise ArgumentError, ~r/must be a keyword list, got: :on/, fn -> GitHubFormatter.config(:on) end
    assert_raise ArgumentError, ~r/must be a keyword list, got: \[1\]/, fn -> GitHubFormatter.config([1]) end

    assert_raise ArgumentError, ~r/max must be a non-negative number, got: -1/, fn ->
      GitHubFormatter.config(report_slow_tests: [max: -1, threshold: 1])
    end

    assert_raise ArgumentError, ~r/threshold must be a non-negative number, got: nil/, fn ->
      GitHubFormatter.config(report_slow_tests: [max: 1])
    end

    assert_raise ArgumentError, ~r/takes \[:max, :threshold\]/, fn ->
      GitHubFormatter.config(report_slow_tests: [top: 1])
    end

    assert_raise ArgumentError, ~r/keyword list or nil/, fn -> GitHubFormatter.config(report_slow_tests: true) end
  end

  test "slow files: the slowest over the threshold, of one module each" do
    Application.put_env(:playwright_ex, GitHubFormatter, report_slow_tests: [max: 2, threshold: 1000])
    project_file = Path.join(File.cwd!(), "test/project_test.exs")

    events = [
      {:test_finished, test_struct("test a", time: 2_000_000)},
      {:test_finished, test_struct("test b", time: 500_000)},
      {:test_finished, test_struct("test c", file: "/tmp/other_test.exs", time: 1_200_000)},
      {:test_finished, test_struct("test d", file: "/tmp/two_modules_test.exs", time: 9_000_000)},
      {:test_finished, test_struct("test e", file: "/tmp/two_modules_test.exs", module: Other)},
      {:test_finished, %{test_struct("test f", file: project_file, time: 3_000_000) | parameters: %{p: 1}}},
      {:suite_finished, %{run: 0, load: nil, async: nil}}
    ]

    assert [project_warning, warning, "::notice " <> _] = String.split(run(events), "\n", trim: true)
    assert project_warning == "::warning title=Slow Test,file=test/project_test.exs::test/project_test.exs took 3.0s"
    assert warning == "::warning title=Slow Test,file=#{@file_path}::#{@file_path} took 2.5s"

    Application.put_env(:playwright_ex, GitHubFormatter, report_slow_tests: nil)
    refute run(events) =~ "::warning"
  end

  test "paths relative to GITHUB_WORKSPACE, also with mix test in a subdirectory; titles relative to the cwd" do
    test = test_struct("test fails", state: {:failed, [{:exit, :boom, []}]})
    cwd = File.cwd!()

    System.put_env("GITHUB_WORKSPACE", Path.dirname(cwd))
    in_workspace = Path.join(Path.basename(cwd), @file_path)
    assert run([{:test_finished, test}]) =~ "::error file=#{in_workspace},title=#{@file_path}%3A10 › fails::"

    System.put_env("GITHUB_WORKSPACE", Path.join(cwd, "test"))
    assert run([{:test_finished, test}]) =~ "::error file=playwright_ex/test/github_formatter_test.exs,"

    System.delete_env("GITHUB_WORKSPACE")
    assert run([{:test_finished, test}]) =~ "::error file=#{@file_path},"
  end

  defp run(events, opts \\ []) do
    capture_io(fn ->
      {:ok, pid} = GenServer.start(GitHubFormatter, opts)
      Enum.each(events, &GenServer.cast(pid, &1))
      GenServer.stop(pid)
    end)
  end

  defp failure(fun) do
    fun.()
  rescue
    e -> {:error, e, __STACKTRACE__}
  end

  defp test_struct(name, opts) do
    tags = %{file: Keyword.get(opts, :file, __ENV__.file), line: Keyword.get(opts, :line, 10), test_type: :test}
    tags = if describe = opts[:describe], do: Map.put(tags, :describe, describe), else: tags
    name = String.to_atom(name)

    %ExUnit.Test{
      name: name,
      module: Keyword.get(opts, :module, __MODULE__),
      state: Keyword.get(opts, :state),
      time: Keyword.get(opts, :time, 0),
      tags: Map.put(tags, :test, name),
      parameters: %{}
    }
  end

  defp rule(n), do: String.duplicate("─", n)
end
