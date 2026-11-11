defmodule PlaywrightEx.Test.ParameterizeTest do
  # Each parameter map of a `parameterize:` module (run at once with `async: true`) and each
  # module of a file has its own recorder and output dir, also for tests of the same name.
  use ExUnit.Case, async: true, parameterize: [%{n: 1}, %{n: 2}]

  import PlaywrightEx.Test

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

  import PlaywrightEx.Test

  alias PlaywrightEx.Test.ParameterizeTest

  setup_all :browser

  test "records", ctx do
    others = for n <- [1, 2], do: Map.merge(ctx, %{module: ParameterizeTest, n: n})
    ParameterizeTest.records(ctx, "OTHER-MODULE", others)
  end
end
