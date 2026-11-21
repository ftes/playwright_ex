defmodule Playwright.Test.CaseTemplateProjectsTest.Template do
  # The projects recipe of guides/test-options.md: a template's default `parameterize:`.
  use ExUnit.CaseTemplate

  using opts do
    opts =
      Keyword.put_new(
        opts,
        :parameterize,
        quote(do: [Playwright.Test.parameters(name: "one"), Playwright.Test.parameters(name: "two")])
      )

    quote do: use(Playwright.Case, unquote(opts))
  end
end

defmodule Playwright.Test.CaseTemplateProjectsTest.DefaultTest do
  use Playwright.Test.CaseTemplateProjectsTest.Template, async: true

  test "runs in each of the template's projects" do
    assert Playwright.Test.info().project.name in ["one", "two"]

    assert for(params <- __MODULE__.__ex_unit__(:config).parameterize, do: params[:"playwright.project"].name) ==
             ["one", "two"]
  end
end

defmodule Playwright.Test.CaseTemplateProjectsTest.OwnTest do
  use Playwright.Test.CaseTemplateProjectsTest.Template,
    async: true,
    parameterize: [Playwright.Test.parameters(name: "own")]

  test "a module's own parameterize: wins" do
    assert Playwright.Test.info().project.name == "own"
  end
end
