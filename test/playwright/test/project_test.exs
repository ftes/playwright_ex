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

  # `info/0`'s project: upstream's `project.use`, the config's options (test_helper.exs sets
  # `browser_name`) under the project's, by the names `use/1` takes, not the runner's.
  test "info's project has the use options by their names, over the config's" do
    browser_name = String.to_existing_atom(Playwright.TestBrowser.name())

    parameters =
      Playwright.Test.parameters(
        [name: "Pixel", color_scheme: :dark, context_options: [reduced_motion: :reduce], trace: :on] ++
          Playwright.device("Pixel 7")
      )

    assert %Playwright.Test.Project{name: "Pixel", use: use} = Options.info_project(Options.project(parameters))
    refute Map.has_key?(use, :context)
    assert use.browser_name == browser_name
    assert use.default_browser_type == :chromium
    assert use.color_scheme == :dark
    assert use.is_mobile
    assert use.viewport == %{width: 412, height: 839}
    assert use.trace[:mode] == :on

    # `context_options` and `launch_options` as given, as upstream's `contextOptions` and
    # `launchOptions` objects: a `nil` key and a device's keys (`default_browser_type`) too.
    bag = [locale: nil] ++ Playwright.device("Pixel 7")
    launch = %{slow_mo: 5, args: ["--x"]}
    project = Options.project(Playwright.Test.parameters(context_options: bag, launch_options: [slow_mo: 5]))
    assert %{context_options: ^bag, launch_options: [slow_mo: 5]} = Options.info_project(project).use
    # A keyword list's later key only, as JS's spread (`{...device, viewport}`) keeps it.
    viewport = %{width: 100, height: 200}
    bag = Playwright.device("Pixel 7") ++ [viewport: viewport]

    project =
      Options.project(Playwright.Test.parameters(context_options: bag, launch_options: [slow_mo: 1, slow_mo: 2]))

    assert %{context_options: given, launch_options: [slow_mo: 2]} = Options.info_project(project).use
    assert given == Playwright.Application.later_wins(bag)
    assert given[:viewport] == viewport
    assert Enum.count(given, &(elem(&1, 0) == :viewport)) == 1

    project = Options.project(Playwright.Test.parameters(context_options: %{locale: "fr-FR"}, launch_options: launch))
    assert %{context_options: %{locale: "fr-FR"}, launch_options: ^launch} = Options.info_project(project).use

    # A `nil` is unset: the config's.
    assert Options.info_project(project(browser_name: nil)).use == %{browser_name: browser_name}
    assert Options.info_project(nil) == %Playwright.Test.Project{name: nil, use: %{browser_name: browser_name}}
  end

  test "an empty name is no name, as upstream's default project's" do
    assert project(name: "", browser_name: :firefox).name == nil
    assert Playwright.Test.Project.title(project(name: "")) == nil

    assert_raise ArgumentError, "Playwright.Test.parameters/1: invalid value :x for name, expected a string", fn ->
      Playwright.Test.parameters(name: :x)
    end
  end
end
