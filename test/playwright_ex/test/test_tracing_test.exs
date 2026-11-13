defmodule PlaywrightEx.Test.TestTracingTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.TestTracing

  describe "trace merge (mergeTraceFiles)" do
    @describetag :tmp_dir

    test "prefixes each chunk's trace files with its index and keeps resources once", %{tmp_dir: dir} do
      chunk = fn name, entries ->
        path = Path.join(dir, name)
        {:ok, _} = :zip.create(String.to_charlist(path), for({n, d} <- entries, do: {String.to_charlist(n), d}))
        path
      end

      a = chunk.("a.zip", [{"trace.trace", "a"}, {"trace.network", "an"}, {"resources/x", "x"}])
      b = chunk.("b.zip", [{"trace.trace", "b"}, {"trace.network", "bn"}, {"resources/x", "x"}, {"resources/y", "y"}])
      merged = Path.join(dir, "out/trace.zip")

      assert TestTracing.merge_trace_files(merged, [a, b, Path.join(dir, "missing.zip")]) == :ok
      {:ok, files} = :zip.unzip(String.to_charlist(merged), [:memory])
      files = Map.new(files, fn {name, data} -> {to_string(name), data} end)

      assert files == %{
               "0-trace.trace" => "a",
               "0-trace.network" => "an",
               "1-trace.trace" => "b",
               "1-trace.network" => "bn",
               "resources/x" => "x",
               "resources/y" => "y"
             }

      refute File.exists?(a) or File.exists?(b)
    end

    test "a single chunk keeps its names, none gives none", %{tmp_dir: dir} do
      path = Path.join(dir, "a.zip")
      {:ok, _} = :zip.create(String.to_charlist(path), [{~c"trace.trace", "a"}, {~c"resources/x", "x"}])
      assert TestTracing.merge_trace_files(Path.join(dir, "t/trace.zip"), [path]) == :ok
      {:ok, files} = :zip.unzip(String.to_charlist(Path.join(dir, "t/trace.zip")), [:memory])
      assert Enum.sort(files) == [{~c"resources/x", "x"}, {~c"trace.trace", "a"}]
      assert TestTracing.merge_trace_files(Path.join(dir, "u/trace.zip"), [path]) == :none
    end
  end
end
