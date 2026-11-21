defmodule Playwright.Test.TestMacroTest do
  # `use Playwright.Test`'s `test` macro: ExUnit reports failures byte for byte as without it
  # (a timed-out test's is upstream's, `Playwright.Test.TimeoutManagerError`), and `mix test --breakpoints` breaks where it would without it (a child BEAM,
  # `test/support/test_macro_impl.exs`).
  use ExUnit.Case, async: true

  alias Playwright.RemoteServer.ChildProcess

  @moduletag timeout: 60_000

  defp run(variant, mode) do
    ebin = Path.dirname(:code.which(Playwright))
    script = Path.join([__DIR__, "..", "..", "support", "test_macro_impl.exs"])
    child = ChildProcess.start(System.find_executable("elixir"), ["-pa", ebin, script, variant, mode])
    on_exit(fn -> ChildProcess.stop(child) end)
    assert ChildProcess.exit_code(child, 60_000) == 0

    child
    |> ChildProcess.output()
    |> String.replace(~r/#PID<[\d.]+>/, "#PID<>")
    |> String.replace(~r/^Finished in .*$/m, "")
  end

  test "failures are reported as without it, the timeout's with upstream's message" do
    [plain, ours] = for variant <- ["plain", "ours"], do: run(variant, "run")
    assert plain =~ ~r"14 tests, 12 failures|Result: 2/14 passed"
    timed_out = ~r/\n +\d+\) test times out \(TestMacroSample\)\n.*?\n(?=\n +\d+\) test )/s
    assert [plain_timeout] = Regex.run(timed_out, plain)
    assert plain_timeout =~ "** (ExUnit.TimeoutError) test timed out after 100ms."
    assert [ours_timeout] = Regex.run(timed_out, ours)
    assert ours_timeout =~ "** (Playwright.Test.TimeoutManagerError) Test timeout of 100ms exceeded."
    assert String.replace(ours, timed_out, "") == String.replace(plain, timed_out, "")
  end

  test "breakpoints before each expression, as without it" do
    [plain, ours] =
      for variant <- ["plain", "ours"] do
        [_, breakpoints] = Regex.run(~r/\(breakpoints=>(%\{.*\})\)/, run(variant, "breakpoints"))
        {breakpoints, []} = Code.eval_string(breakpoints)
        breakpoints
      end

    assert plain == %{"test three expressions": 3, "test one expression": 1, "test a describe two expressions": 2}
    assert ours == plain
  end

  test "use Playwright.Test comes after use ExUnit.Case" do
    assert_raise CompileError, ~r/use Playwright.Test must come after use ExUnit.Case/, fn ->
      Code.compile_string("defmodule Playwright.Test.TestMacroTest.Early, do: use(Playwright.Test)")
    end
  end
end
