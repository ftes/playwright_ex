defmodule PlaywrightEx.Test.TestMacroTest do
  # `use PlaywrightEx.Test`'s `test` macro: ExUnit reports failures byte for byte as without it,
  # and `mix test --breakpoints` breaks where it would without it (a child BEAM,
  # `test/support/test_macro_impl.exs`).
  use ExUnit.Case, async: true

  alias PlaywrightEx.RemoteServer.ChildProcess

  @moduletag timeout: 60_000

  defp run(variant, mode) do
    ebin = Path.dirname(:code.which(PlaywrightEx))
    script = Path.join([__DIR__, "..", "..", "support", "test_macro_impl.exs"])
    child = ChildProcess.start(System.find_executable("elixir"), ["-pa", ebin, script, variant, mode])
    on_exit(fn -> ChildProcess.stop(child) end)
    assert ChildProcess.exit_code(child, 60_000) == 0

    child
    |> ChildProcess.output()
    |> String.replace(~r/#PID<[\d.]+>/, "#PID<>")
    |> String.replace(~r/^Finished in .*$/m, "")
  end

  test "failures are reported as without it" do
    [plain, ours] = for variant <- ["plain", "ours"], do: run(variant, "run")
    assert plain =~ ~r"14 tests, 12 failures|Result: 2/14 passed"
    assert ours == plain
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

  test "use PlaywrightEx.Test comes after use ExUnit.Case" do
    assert_raise CompileError, ~r/use PlaywrightEx.Test must come after use ExUnit.Case/, fn ->
      Code.compile_string("defmodule PlaywrightEx.Test.TestMacroTest.Early, do: use(PlaywrightEx.Test)")
    end
  end

  test "use PlaywrightEx.Test takes no options" do
    assert_raise ArgumentError, ~r/use PlaywrightEx.Test takes no options, got: \[isolate: true\]/, fn ->
      Code.compile_string("""
      defmodule PlaywrightEx.Test.TestMacroTest.Options do
        use ExUnit.Case
        use PlaywrightEx.Test, isolate: true
      end
      """)
    end
  end
end
