# Spike 4: exposeBinding/exposeFunction handlers call back into Playwright while the
# user's evaluate that triggered them is still awaiting.
defmodule PlaywrightJS.ReentrancyTest do
  use ExUnit.Case, async: false
  alias PlaywrightJS.TestHelper
  alias PlaywrightJS.Client.{BrowserContext, Locator, Page}

  test "binding handler calls page.evaluate, locator text and nested bindings mid-evaluate" do
    %{page: page} = env = TestHelper.launch()
    Page.goto(page, TestHelper.fixture_url("form.html"))

    Page.expose_function(page, "inner", fn x ->
      # Two levels deep: evaluate -> compute -> evaluate -> inner -> locator
      "#{x}:" <> (page |> Page.locator("h1") |> Locator.text_content())
    end)

    Page.expose_function(page, "compute", fn a, b ->
      title = Page.title(page)
      nested = Page.evaluate(page, "async () => await window.inner('deep')")
      sum = Page.evaluate(page, "([a, b]) => a + b", [a, b])
      %{"title" => title, "nested" => nested, "sum" => sum}
    end)

    Page.expose_binding(page, "whoami", fn source, suffix ->
      Page.url(source.page) |> Path.basename() |> Kernel.<>(suffix)
    end)

    for _ <- 1..10 do
      assert Page.evaluate(page, "async () => await window.compute(2, 3)") ==
               %{"title" => "Sign up", "nested" => "deep:Sign up", "sum" => 5}
    end

    assert Page.evaluate(page, "window.whoami('!')") == "form.html!"
    TestHelper.close(env)
  end

  test "context-level binding and handler errors reject in the page" do
    %{page: page, context: context} = env = TestHelper.launch()
    BrowserContext.expose_function(context, "boom", fn -> raise "kaboom" end)
    BrowserContext.expose_function(context, "ctxTitle", fn -> Page.title(page) end)
    Page.goto(page, TestHelper.fixture_url("form.html"))
    assert Page.evaluate(page, "window.ctxTitle()") == "Sign up"
    assert Page.evaluate(page, "window.boom().then(() => 'ok', e => 'rejected: ' + e.message)") =~ "rejected: kaboom"
    TestHelper.close(env)
  end

  test "concurrent evaluates from several processes each triggering re-entrant bindings" do
    %{page: page} = env = TestHelper.launch()
    Page.goto(page, TestHelper.fixture_url("form.html"))
    Page.expose_function(page, "echo", fn x -> Page.evaluate(page, "(x) => x * 2", x) end)

    results =
      1..10
      |> Enum.map(fn i -> Task.async(fn -> Page.evaluate(page, "(i) => window.echo(i)", i) end) end)
      |> Task.await_many(10_000)

    assert results == Enum.map(1..10, &(&1 * 2))
    TestHelper.close(env)
  end
end
