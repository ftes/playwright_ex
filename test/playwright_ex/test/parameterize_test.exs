defmodule PlaywrightEx.Test.ParameterizeTest do
  # Each parameter map of a `parameterize:` module (run at once with `async: true`) and each
  # module of a file has its own recorder and output dir, also for tests of the same name.
  use ExUnit.Case, async: true, parameterize: [%{n: 1}, %{n: 2}]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.TestInfo

  setup_all do: %{browser: BrowserPool.browser()}

  # Before the registration, so its `on_exit` runs after the test's end has saved the trace.
  setup ctx, do: check(ctx, "PARAM-#{ctx.n}", [%{ctx | n: 3 - ctx.n}, %{ctx | module: __MODULE__.Other}])

  use PlaywrightEx.Test

  @moduletag trace: :on

  def check(ctx, marker, others) do
    dir = TestInfo.output_dir(ctx)
    for other <- others, do: refute(TestInfo.output_dir(other) == dir)

    on_exit(fn ->
      # With its `-retryN` suffix under `mix test --failed`.
      dir = PlaywrightEx.Test.info(ctx.test_pid).output_dir
      assert File.ls!(dir) == ["trace.zip"]
      trace = PlaywrightEx.Utils.parse_trace_raw(Path.join(dir, "trace.zip"), ctx.browser)
      text = JSON.encode!(trace.events)
      assert text =~ marker
      for other <- ["PARAM-1", "PARAM-2", "OTHER-MODULE"] -- [marker], do: refute(text =~ other)
      File.rm_rf!(dir)
    end)
  end

  def record(browser, marker) do
    page = BrowserContext.new_page!(Browser.new_context!(browser))
    Page.set_content!(page, "<h1>#{marker}</h1>")
    # Long enough for the other parameter set's test to run alongside.
    Process.sleep(200)
  end

  test("records", %{browser: browser, n: n}, do: record(browser, "PARAM-#{n}"))
end

defmodule PlaywrightEx.Test.ParameterizeTest.Other do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.ParameterizeTest

  setup_all do: %{browser: BrowserPool.browser()}

  setup ctx do
    others = for n <- [1, 2], do: Map.merge(ctx, %{module: ParameterizeTest, n: n})
    ParameterizeTest.check(ctx, "OTHER-MODULE", others)
  end

  use PlaywrightEx.Test

  @moduletag trace: :on

  test("records", %{browser: browser}, do: ParameterizeTest.record(browser, "OTHER-MODULE"))
end

defmodule PlaywrightEx.Test.ParameterizeTest.Shapes do
  # `__ex_unit__(:config)` is internal ExUnit API: another shape means no parameters.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.TestInfo

  for {name, config} <- [missing: [], other: %{parameterize: :none}, keyword: :none] do
    defmodule Module.concat(__MODULE__, name) do
      def __ex_unit__(:config), do: unquote(Macro.escape(config))
    end
  end

  test "an unknown shape of ExUnit's module config is no parameters" do
    for name <- [:missing, :other, :keyword],
        do: assert(TestInfo.parameters(Module.concat(__MODULE__, name), %{n: 1}) == %{})

    assert TestInfo.parameters(PlaywrightEx.Test.ParameterizeTest, %{n: 2}) == %{n: 2}
  end
end

defmodule PlaywrightEx.Test.ParameterizeTest.Overwritten do
  # A `setup` before the registration overwrites a parameter: each parameter set still gets an
  # output dir of its own (the runner's parameters, not a guess from the context), so neither
  # deletes the other's.
  use ExUnit.Case, async: true, parameterize: [%{n: 1}, %{n: 2}]

  alias PlaywrightEx.Test.TestInfo

  setup ctx, do: %{param: ctx.n, n: :overwritten}

  use PlaywrightEx.Test

  test "gets its parameter set's output dir", %{param: n} = ctx do
    dir = Path.expand(TestInfo.output_dir(%{ctx | n: n}))
    # With its `-retryN` suffix under `mix test --failed`.
    assert PlaywrightEx.Test.info().output_dir =~ ~r/^#{Regex.escape(dir)}(-retry\d+)?$/
  end
end
