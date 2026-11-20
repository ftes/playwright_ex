defmodule Playwright.Test.ProjectTest do
  # `Playwright.Test.parameters/1`'s project: its name, as upstream's `project.name`, which a
  # failed test prints; an unnamed one prints as its options.
  use ExUnit.Case, async: true

  alias Playwright.Test.Options
  alias Playwright.Test.TestInfo

  defp project(opts), do: Options.project(Playwright.Test.parameters(opts))

  test "a named project inspects as its name, the testInfo's project name" do
    parameters = Playwright.Test.parameters([name: "Mobile Safari"] ++ Playwright.device("iPhone 13"))
    assert inspect(Options.project(parameters)) == ~s(#Playwright.Test.Project<"Mobile Safari">)
    assert Playwright.Test.Project.title(Options.project(parameters)) == "Mobile Safari"
    assert TestInfo.project_name(parameters) == "Mobile Safari"
  end

  test "an unnamed project has no title, as upstream's: it inspects as its options" do
    for opts <- [Playwright.device("iPhone 13"), [browser_name: :firefox], [locale: "de-DE"]] do
      assert Playwright.Test.Project.title(project(opts)) == nil
      assert "#Playwright.Test.Project<%{" <> _ = inspect(project(opts))
      assert TestInfo.project_name(Playwright.Test.parameters(opts)) == ""
    end
  end

  test "an empty name is no name, as upstream's default project's" do
    assert project(name: "", browser_name: :firefox).name == nil
    assert Playwright.Test.Project.title(project(name: "")) == nil

    assert_raise ArgumentError, "Playwright.Test.parameters/1: invalid value :x for name, expected a string", fn ->
      Playwright.Test.parameters(name: :x)
    end
  end
end
