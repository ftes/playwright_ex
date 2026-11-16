defmodule Playwright.CaseTest.Extended do
  # A template built on `Playwright.Case`: setup in its `using` runs after the page's (its own
  # `setup` would run before them).
  use ExUnit.CaseTemplate

  using do
    quote do
      use Playwright.Case

      setup %{page: page} do
        Playwright.Page.set_content!(page, "<h1>Extended</h1>")
        :ok
      end
    end
  end
end

defmodule Playwright.CaseTest do
  use Playwright.Case, async: true

  test "a test gets a context of the module's browser and a page of it, recorded", ctx do
    %{browser: browser, context: context, page: page} = ctx
    assert Page.context(page) == context
    assert BrowserContext.browser(context) == browser
    # The module holds it (`setup_all`): the test's own call is the module's.
    assert BrowserPool.browser() == browser
    assert is_pid(Playwright.Test.Recorder.lookup(self()))
    Page.set_content!(page, "<h1>Hi</h1>")
    Page.get_by_role(page, :heading) |> Expect.to_have_text!("Hi")
  end

  test "the context has Playwright Test's defaults", %{page: page} do
    assert Page.evaluate!(page, "navigator.language") == "en-US"
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
  end
end

defmodule Playwright.CaseTest.ExtendedTest do
  use Playwright.CaseTest.Extended, async: true

  test "a template's setup after the page's", %{page: page} do
    Page.get_by_role(page, :heading) |> Expect.to_have_text!("Extended")
  end
end
