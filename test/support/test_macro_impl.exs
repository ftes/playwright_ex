# The child BEAM of `Playwright.Test.TestMacroTest`: one test module, as plain ExUnit compiles
# it (`plain`) or with `use Playwright.Test` (`ours`), from one source with the same lines.
#
# Runs as `elixir -pa <playwright ebin> test_macro_impl.exs <plain|ours> <run|breakpoints>`:
# `run` runs the module (seed 0); `breakpoints` compiles it as `mix test --breakpoints` does and
# prints how many breakpoints each test function has: `(breakpoints=>%{...})`.

Playwright.ClientProcess.halt_on_stdin_eof()

[variant, mode] = System.argv()
use_line = if variant == "ours", do: "use ExUnit.Case; use Playwright.Test", else: "use ExUnit.Case"

source = """
defmodule TestMacroSample do
  #{use_line}

  test "passes" do
    a = 1
    assert a == 1
  end

  test "an assertion" do
    a = 1
    assert a + 1 ==
             3
  end

  test "raises" do
    raise ArgumentError, "boom"
  end

  test "exits", do: exit(:boom)

  test "throws", do: throw(:ball)

  test "fails in a helper", do: helper(2)

  test "rescues", ctx do
    raise "rescued"
  rescue
    e in RuntimeError -> assert e.message == "rescued" and is_map(ctx)
  end

  test "fails before its after clause" do
    raise "boom"
  after
    send(self(), :after)
  end

  test "a raise in rescue" do
    raise "first"
  rescue
    _ -> raise "second"
  end

  @tag timeout: 100
  test "times out", do: Process.sleep(1_000)

  test "a linked process exits" do
    spawn_link(fn -> exit(:linked) end)
    Process.sleep(1_000)
  end

  test "not implemented"

  describe "a describe" do
    test "fails", do: flunk("in a describe")
  end

  describe "a failing setup" do
    setup do: raise("setup boom")

    test "never runs", do: :ok
  end

  describe "a failing on_exit" do
    setup ctx do
      on_exit(fn ->
        case ctx.fail do
          :raise -> raise "on_exit boom"
          :exit -> exit(:on_exit_boom)
          :throw -> throw(:on_exit_ball)
        end
      end)
    end

    @tag fail: :raise
    test "raises", do: :ok

    @tag fail: :exit
    test "exits", do: :ok

    @tag fail: :throw
    test "throws", do: :ok
  end

  test "fails in an on_exit of its body" do
    on_exit(fn -> helper(2) end)
  end

  # Not its tail call: `use Playwright.Test`'s `assert` records its step after ExUnit's, so a
  # function that ends in a failing one keeps its frame (`Playwright.Test.AssertionsTest`).
  defp helper(n) do
    assert n == 1
    n
  end
end
"""

# ExUnit's own breakpoints don't compile `rescue`, `catch` or `after` bodies: do-bodies only.
breakpoints_source = """
defmodule TestMacroSample do
  #{use_line}

  test "three expressions" do
    a = 1
    b = a + 1
    assert b == 2
  end

  test "one expression", do: assert(true)

  describe "a describe" do
    test "two expressions", ctx do
      a = ctx
      assert is_map(a)
    end
  end
end
"""

# A failed test's `error-context.md` goes to a dir of the run's own.
output_dir = Path.join(System.tmp_dir!(), "playwright-test_macro-#{System.unique_integer([:positive])}")
Application.put_env(:playwright, :test, output_dir: output_dir)
ExUnit.start(autorun: false, seed: 0, colors: [enabled: false])
ExUnit.after_suite(fn _ -> File.rm_rf!(output_dir) end)

case mode do
  "run" ->
    Code.compile_string(source, "test/test_macro_sample_test.exs")
    ExUnit.run()

  "breakpoints" ->
    # `mix test --breakpoints` (`IEx.Pry.annotate_quoted/3` on each test's body).
    Application.put_env(:ex_unit, :breakpoints, true)
    [{module, binary}] = Code.compile_string(breakpoints_source, "test/test_macro_sample_test.exs")
    {:ok, {_, [debug_info: {:debug_info_v1, backend, data}]}} = :beam_lib.chunks(binary, [:debug_info])
    {:ok, %{definitions: definitions}} = backend.debug_info(:elixir_v1, module, data, [])

    breakpoints =
      for {{name, 1}, :def, _meta, clauses} <- definitions, String.starts_with?(to_string(name), "test "), into: %{} do
        {_, count} =
          Macro.prewalk(for({_meta, _args, _guards, body} <- clauses, do: body), 0, fn
            {{:., _, [IEx.Pry, :__next__]}, _, _} = ast, count -> {ast, count + 1}
            ast, count -> {ast, count}
          end)

        {name, count}
      end

    IO.puts("(breakpoints=>#{inspect(breakpoints)})")
end

System.halt(0)
