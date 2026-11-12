defmodule PlaywrightEx.Test.ParameterizeTest do
  # Each parameter map of a `parameterize:` module (run at once with `async: true`) and each
  # module of a file has its own recorder and output dir, also for tests of the same name.
  use ExUnit.Case, async: true, parameterize: [%{n: 1}, %{n: 2}]

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.BrowserPool
  alias PlaywrightEx.Test.Recorder

  # Before the registration, so its `on_exit` runs after the test's end has saved the trace.
  setup ctx, do: check(ctx, "PARAM-#{ctx.n}", [%{ctx | n: 3 - ctx.n}, %{ctx | module: __MODULE__.Other}])

  use PlaywrightEx.Test

  @moduletag trace: :on

  def check(ctx, marker, others) do
    dir = Recorder.output_dir(ctx)
    for other <- others, do: refute(Recorder.output_dir(other) == dir)

    on_exit(fn ->
      assert File.ls!(dir) == ["trace.zip"]
      trace = PlaywrightEx.Utils.parse_trace_raw(Path.join(dir, "trace.zip"), BrowserPool.shared())
      text = JSON.encode!(trace.events)
      assert text =~ marker
      for other <- ["PARAM-1", "PARAM-2", "OTHER-MODULE"] -- [marker], do: refute(text =~ other)
      File.rm_rf!(dir)
    end)
  end

  def record(marker) do
    page = BrowserContext.new_page!(Browser.new_context!(BrowserPool.shared()))
    Page.set_content!(page, "<h1>#{marker}</h1>")
    # Long enough for the other parameter set's test to run alongside.
    Process.sleep(200)
  end

  test("records", %{n: n}, do: record("PARAM-#{n}"))
end

defmodule PlaywrightEx.Test.ParameterizeTest.Other do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.ParameterizeTest

  setup ctx do
    others = for n <- [1, 2], do: Map.merge(ctx, %{module: ParameterizeTest, n: n})
    ParameterizeTest.check(ctx, "OTHER-MODULE", others)
  end

  use PlaywrightEx.Test

  @moduletag trace: :on

  test "records", do: ParameterizeTest.record("OTHER-MODULE")
end

defmodule PlaywrightEx.Test.ParameterizeTest.Shapes do
  # `__ex_unit__(:config)` is internal ExUnit API: another shape means no parameters.
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.Recorder

  for {name, config} <- [missing: [], other: %{parameterize: :none}, keyword: :none] do
    defmodule Module.concat(__MODULE__, name) do
      def __ex_unit__(:config), do: unquote(Macro.escape(config))
    end
  end

  test "an unknown shape of ExUnit's module config is no parameters" do
    for name <- [:missing, :other, :keyword],
        do: assert(Recorder.parameters(Module.concat(__MODULE__, name), %{n: 1}) == %{})

    assert Recorder.parameters(PlaywrightEx.Test.ParameterizeTest, %{n: 2}) == %{n: 2}
  end
end
