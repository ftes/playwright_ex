defmodule Playwright.Test.ProjectTest do
  # `Playwright.Test.parameters/1`'s project: its name, else the browser it runs on, as a failed
  # test prints it. Sync: the config's `browser_name` is global.
  use ExUnit.Case, async: false

  alias Playwright.Test.Options
  alias Playwright.Test.TestInfo

  defp project(opts), do: Options.project(Playwright.Test.parameters(opts))

  # The test config with `browser_name` as given (test_helper.exs sets the suite's).
  defp put_browser_name(browser_name) do
    config = Application.get_env(:playwright, :test)
    on_exit(fn -> Application.put_env(:playwright, :test, config) end)
    Application.put_env(:playwright, :test, Keyword.put(config, :browser_name, browser_name))
  end

  test "a named project inspects as its name, the testInfo's project name" do
    parameters = Playwright.Test.parameters([name: "Mobile Safari"] ++ Playwright.device("iPhone 13"))
    assert inspect(Options.project(parameters)) == ~s(#Playwright.Test.Project<"Mobile Safari">)
    assert TestInfo.project_name(parameters) == "Mobile Safari"
  end

  test "an unnamed project inspects as the browser it runs on, else its options" do
    put_browser_name(nil)
    assert inspect(project(Playwright.device("iPhone 13"))) == ~s(#Playwright.Test.Project<"webkit">)
    assert inspect(project(browser_name: :firefox)) == ~s(#Playwright.Test.Project<"firefox">)
    assert "#Playwright.Test.Project<%{" <> _ = inspect(project(locale: "de-DE"))
    assert TestInfo.project_name(Playwright.Test.parameters(locale: "de-DE")) == ""
  end

  test "a configured browser_name beats a device's default_browser_type, as BrowserPool.browser/1" do
    put_browser_name(:firefox)
    assert inspect(project(Playwright.device("iPhone 13"))) == ~s(#Playwright.Test.Project<"firefox">)
    # The project's own browser_name beats the config's.
    assert inspect(project(browser_name: :webkit)) == ~s(#Playwright.Test.Project<"webkit">)
  end

  test "an empty name is no name, as upstream's default project's" do
    assert project(name: "", browser_name: :firefox).name == nil
    assert inspect(project(name: "", browser_name: :firefox)) == ~s(#Playwright.Test.Project<"firefox">)

    assert_raise ArgumentError, "Playwright.Test.parameters/1: invalid value :x for name, expected a string", fn ->
      Playwright.Test.parameters(name: :x)
    end
  end
end
