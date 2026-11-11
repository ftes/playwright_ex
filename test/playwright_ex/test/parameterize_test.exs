defmodule PlaywrightEx.Test.ParameterizeTest do
  # Each parameter map of a `parameterize:` module (run at once with `async: true`) and each
  # module of a file has its own recorder and output dir, also for tests of the same name.
  use ExUnit.Case, async: true, parameterize: [%{n: 1}, %{n: 2}]

  use PlaywrightEx.Test

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Page
  alias PlaywrightEx.Test.Recorder

  setup_all :browser

  def records(ctx, marker, others) do
    dir = Recorder.output_dir(ctx)
    for other <- others, do: refute(Recorder.output_dir(other) == dir)

    on_exit(fn ->
      assert File.ls!(dir) == ["trace.zip"]
      trace = PlaywrightEx.Utils.parse_trace_raw(Path.join(dir, "trace.zip"), ctx.browser)
      text = JSON.encode!(trace.events)
      assert text =~ marker
      for other <- ["PARAM-1", "PARAM-2", "OTHER-MODULE"] -- [marker], do: refute(text =~ other)
      File.rm_rf!(dir)
    end)

    record_artifacts(ctx, trace: :on)
    %{context: context} = new_context(ctx)
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<h1>#{marker}</h1>")
    # Long enough for the other parameter set's test to run alongside.
    Process.sleep(200)
  end

  test "records", %{n: n} = ctx do
    others = [%{ctx | n: 3 - n}, %{ctx | module: __MODULE__.Other}]
    records(ctx, "PARAM-#{n}", others)
  end
end

defmodule PlaywrightEx.Test.ParameterizeTest.Other do
  use ExUnit.Case, async: true

  use PlaywrightEx.Test

  alias PlaywrightEx.Test.ParameterizeTest

  setup_all :browser

  test "records", ctx do
    others = for n <- [1, 2], do: Map.merge(ctx, %{module: ParameterizeTest, n: n})
    ParameterizeTest.records(ctx, "OTHER-MODULE", others)
  end
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
