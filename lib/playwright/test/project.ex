defmodule Playwright.Test.Project do
  @moduledoc """
  A project of `Playwright.Test.parameters/1`, upstream's `projects: [{ name, use }]` entry: its
  `name` and its `use` options, validated. It is the value of one private parameter, and
  inspects as its `title/1`, so a failed test prints a short name, as upstream's reporters print
  the project's: `Parameters: %{"playwright.project": #Playwright.Test.Project<"Mobile Safari">}`.
  """

  @enforce_keys [:name, :use]
  defstruct [:name, :use]

  @typedoc "`name` (`nil` when not given) and `use`, the options as `Playwright.Test` reads them."
  @type t :: %__MODULE__{name: String.t() | nil, use: map()}

  @doc """
  The project's title: its `name`, else its browser (its `browser_name`, else a device's
  `default_browser_type`), as upstream names its default projects; `nil` without either.
  """
  @spec title(t()) :: String.t() | nil
  def title(%__MODULE__{name: name, use: use}) do
    browser = use[:browser_name] || use[:default_browser_type]
    name || (browser && to_string(browser))
  end

  defimpl Inspect do
    import Inspect.Algebra

    # Its title; a project with neither a name nor a browser has only its options to tell it by.
    def inspect(project, opts) do
      doc = to_doc(Playwright.Test.Project.title(project) || project.use, opts)
      concat(["#Playwright.Test.Project<", doc, ">"])
    end
  end
end
