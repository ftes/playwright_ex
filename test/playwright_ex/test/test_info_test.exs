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
end
