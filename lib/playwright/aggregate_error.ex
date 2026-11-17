defmodule Playwright.AggregateError do
  @moduledoc """
  Every promise of `Playwright.Promise.any/1` was rejected. As JS's `AggregateError`, `errors`
  lists the rejections in input order (`[]` for `any([])`). It is a `t:Playwright.error/0`, which
  `Playwright.Promise.await/1` returns, only when each of them is; otherwise it raises.
  """
  @typedoc "See the module docs for the fields."
  @type t :: %__MODULE__{message: String.t(), errors: [term()]}

  defexception message: "All promises were rejected", errors: []
end
