defmodule Playwright.AggregateError do
  @moduledoc """
  Every promise of `Playwright.Promise.any/1` was rejected. As JS's `AggregateError`, `errors`
  lists the rejections in input order (`[]` for `any([])`). `Playwright.Promise.await/1` returns
  it when each of them is a `t:Playwright.error/0`, and raises it otherwise.
  """
  @typedoc "See the module docs for the fields."
  @type t :: %__MODULE__{message: String.t(), errors: [term()]}

  defexception message: "All promises were rejected", errors: []
end
