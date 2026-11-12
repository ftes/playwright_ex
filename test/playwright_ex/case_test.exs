defmodule PlaywrightEx.CaseTest.Extended do
  # A template built on `PlaywrightEx.Case`: setup in its `using` runs after the page's (its own
  # `setup` would run before them).
  use ExUnit.CaseTemplate

  using do
    quote do
      use PlaywrightEx.Case

      setup %{page: page} do
        PlaywrightEx.Page.set_content!(page, "<h1>Extended</h1>")
        :ok
      end
    end
  end
end

defmodule PlaywrightEx.CaseTest do
  use PlaywrightEx.Case, async: true

  test "a test gets a context of the shared browser and a page of it, recorded", %{context: context, page: page} do
    assert Page.context(page) == context
    assert BrowserContext.browser(context) == BrowserPool.shared()
    assert is_pid(PlaywrightEx.Test.Recorder.lookup(self()))
    Page.set_content!(page, "<h1>Hi</h1>")
    Page.get_by_role(page, :heading) |> Expect.to_have_text!("Hi")
  end

  test "the context has Playwright Test's defaults", %{page: page} do
    assert Page.evaluate!(page, "navigator.language") == "en-US"
    assert Page.viewport_size(page) == %{width: 1280, height: 720}
  end
end

defmodule PlaywrightEx.CaseTest.ExtendedTest do
  use PlaywrightEx.CaseTest.Extended, async: true

  test "a template's setup after the page's", %{page: page} do
    Page.get_by_role(page, :heading) |> Expect.to_have_text!("Extended")
  end
end
