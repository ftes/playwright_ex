defmodule Playwright.StepLibrary do
  # A library's helpers on `Playwright.Test.step/3`, for `Playwright.Test.StepsTest`. An `.exs`, so
  # its module is no `:playwright` module (the stack filters drop those), as a dependency's isn't.
  @moduledoc false

  alias Playwright.Expect
  alias Playwright.Test

  require Test

  def assert_text_do(locator, text) do
    Test.step "assert text do", box: true do
      Expect.to_have_text!(locator, text, timeout: 1)
    end
  end

  def assert_text_fn(locator, text) do
    Test.step("assert text fn", fn -> Expect.to_have_text!(locator, text, timeout: 1) end, box: true)
  end

  def boxed_at(location) do
    Test.step "boxed at", box: true, location: location do
      :ok
    end
  end

  def unboxed_do do
    Test.step "unboxed do", box: false do
      :ok
    end
  end
end
