defmodule PlaywrightEx.Test.TestInfoTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Test.TestInfo

  describe "parameters" do
    defmodule Weird do
      def __ex_unit__(:config), do: [parameterize: [%{n: 1}]]
    end

    defmodule Parameterized do
      def __ex_unit__(:config), do: %{parameterize: [%{n: 1, m: 1}, %{n: 2, m: 1}]}
    end

    test "are the parameter map whose values the context has" do
      assert TestInfo.parameters(Parameterized, %{n: 2, m: 1, test: :t}) == %{n: 2, m: 1}
      assert TestInfo.parameters(Parameterized, %{n: 3, m: 1}) == %{}
      assert TestInfo.parameters(__MODULE__, %{n: 1}) == %{}
    end

    test "are %{} when ExUnit's internal config is missing or of another shape" do
      assert TestInfo.parameters(M, %{n: 1}) == %{}
      assert TestInfo.parameters(Weird, %{n: 1}) == %{}
    end
  end

  describe "output dirs" do
    defp output_dir(file, name, module \\ MyApp.CheckoutTest, parameters \\ %{}) do
      dir = TestInfo.output_dir("out", file, name, module, parameters)
      assert [_, name] = Regex.run(~r"^out/(.*)-[0-9a-f]{5}$", dir)
      name
    end

    test "as upstream's testInfo.outputDir: the file relative to test/, then the sanitized test name" do
      file = Path.join(File.cwd!(), "test/my_app/checkout_test.exs")
      assert output_dir(file, "pays by card") == "my_app-checkout-pays-by-card"
      assert output_dir(file, "cart: add_item/2 (EUR)") == "my_app-checkout-cart-add-item-2-EUR-"
    end

    test "a file outside test/ is relative to the working directory" do
      assert output_dir(Path.join(File.cwd!(), "e2e/flow_test.exs"), "a") == "e2e-flow-a"
    end

    test "long names are trimmed to 60 characters with a hash, as trimLongString" do
      file = Path.join(File.cwd!(), "test/my_app/checkout_test.exs")
      name = output_dir(file, String.duplicate("very long name ", 6))
      assert String.length(name) == 60
      assert name =~ ~r/^my_app-checkout-very-long--[0-9a-f]{5}-y-long-name-very-long-name-$/
    end

    test "the suffix tells modules of one file and parameters apart" do
      file = Path.join(File.cwd!(), "test/my_app/checkout_test.exs")

      dirs =
        for {module, parameters} <- [
              {MyApp.ATest, %{}},
              {MyApp.BTest, %{}},
              {MyApp.ATest, %{n: 1}},
              {MyApp.ATest, %{n: 2}}
            ],
            do: TestInfo.output_dir("out", file, "pays", module, parameters)

      assert length(Enum.uniq(dirs)) == 4
      assert TestInfo.output_dir("out", file, "pays", MyApp.ATest, %{}) == hd(dirs)
    end

    test "the test name is without its macro's prefix, test_type's" do
      assert TestInfo.test_name(%{test: :"test pays", test_type: :test}) == "pays"
      assert TestInfo.test_name(%{test: :"feature pays", test_type: :feature}) == "pays"
      assert TestInfo.test_name(%{test: :"test pays"}) == "pays"
    end

    test "sanitizeForFilePath keeps letters, digits, dashes and non-ASCII" do
      assert TestInfo.sanitize_for_file_path("a_b.c/d e:f-ü") == "a-b-c-d-e-f-ü"
    end
  end

  describe "retries" do
    @describetag :tmp_dir

    # The dirs of a test `pays-1a2b3`, and of others: none ends in `-retryN` after its hash.
    defp dirs(tmp_dir, names) do
      for name <- names, do: File.mkdir_p!(Path.join([tmp_dir, name, "x"]))
      Path.join(tmp_dir, "pays-1a2b3")
    end

    defp ls(tmp_dir), do: tmp_dir |> File.ls!() |> Enum.sort()

    test "a test under --failed (only_test_ids) is the retry after its -retryN dirs; else 0", %{tmp_dir: tmp_dir} do
      dir = dirs(tmp_dir, [])
      assert TestInfo.retry(dir, MapSet.new()) == 1
      assert TestInfo.retry(dir, nil) == 0

      dirs(tmp_dir, ["pays-1a2b3", "pays-1a2b3-retry1", "pays-1a2b3-retry3", "pays-1a2b3-retry0", "pays-1a2b3-retryx"])
      assert TestInfo.retry(dir, MapSet.new()) == 4
      assert TestInfo.retry(dir, nil) == 0
      assert TestInfo.retry(Path.join([tmp_dir, "missing", "pays-1a2b3"]), MapSet.new()) == 1
    end

    test "a first run removes the test's dir and its -retryN dirs, a retry only its own", %{tmp_dir: tmp_dir} do
      others = ["pays-1a2b3-retryx", "pays-4d5e6", "pays-4d5e6-retry1"]
      dir = dirs(tmp_dir, ["pays-1a2b3", "pays-1a2b3-retry1", "pays-1a2b3-retry2" | others])

      assert TestInfo.remove_output_dirs(%{output_dir: dir <> "-retry2", retry: 2}) == :ok
      assert ls(tmp_dir) == Enum.sort(["pays-1a2b3", "pays-1a2b3-retry1" | others])

      assert TestInfo.remove_output_dirs(%{output_dir: dir, retry: 0}) == :ok
      assert ls(tmp_dir) == Enum.sort(others)
    end
  end
end

defmodule PlaywrightEx.Test.TestInfoTest.RemoveOutputDirTest do
  # A test's dir and its `-retryN` dirs of an earlier run, removed before it runs (or, under
  # `mix test --failed`, its next `-retryN` dir written).
  use ExUnit.Case, async: true
  use PlaywrightEx.Test

  alias PlaywrightEx.Test.TestInfo

  setup_all do
    dir =
      TestInfo.output_dir(%{module: __MODULE__, test: :"test runs with no files of an earlier run", file: __ENV__.file})

    for dir <- [dir, dir <> "-retry1"] do
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "error-context.md"), "")
    end

    on_exit(fn -> for dir <- [dir, dir <> "-retry1", dir <> "-retry2"], do: File.rm_rf!(dir) end)
    %{dir: Path.expand(dir)}
  end

  test "runs with no files of an earlier run", %{dir: dir} do
    if ExUnit.configuration()[:only_test_ids] do
      assert PlaywrightEx.Test.info().output_dir == dir <> "-retry2"
      assert File.exists?(Path.join(dir, "error-context.md"))
    else
      assert PlaywrightEx.Test.info().output_dir == dir
      refute File.exists?(dir)
      refute File.exists?(dir <> "-retry1")
    end
  end
end
