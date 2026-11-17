defmodule Playwright.AggregateError do
  @moduledoc """
  Every promise of `Playwright.Promise.any/1` was rejected. As JS's `AggregateError`, `errors`
  lists the rejections in input order (`[]` for `any([])`).
  """
  @typedoc "See the module docs for the fields."
  @type t :: %__MODULE__{message: String.t(), errors: [Playwright.error()]}

  defexception message: "All promises were rejected", errors: []
end
