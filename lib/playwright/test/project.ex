defmodule Playwright.Test.Project do
  @moduledoc """
  A project of `Playwright.Test.parameters/1`, upstream's `projects: [{ name, use }]` entry: its
  `name` and its `use` options, validated. It is the value of one private parameter, and
  inspects as its `title/1`, so a failed test prints a short name, as upstream's reporters print
  the project's: `Parameters: %{"playwright.project": #Playwright.Test.Project<"Mobile Safari">}`.
  An unnamed project, as upstream's, has no title: it inspects as its options.

  `Playwright.Test.info/0`'s `project` is one too, upstream's `testInfo.project`: there `use` is
  upstream's `project.use`, the config's options with the project's over them, by `use/1`'s
  names (`locale`, `base_url`, ...).
  """

  @enforce_keys [:name, :use]
  defstruct [:name, :use]

  @typedoc """
  `name` (`nil` when not given) and `use`: the options as `Playwright.Test` reads them, in
  `Playwright.Test.info/0`'s by `use/1`'s names.
  """
  @type t :: %__MODULE__{name: String.t() | nil, use: map()}

  @doc "The project's title: its `name`, upstream's `project.name`; `nil` for an unnamed project."
  @spec title(t()) :: String.t() | nil
  def title(%__MODULE__{name: name}), do: name

  defimpl Inspect do
    import Inspect.Algebra

    # Its title; an unnamed project has only its options to tell it by.
    def inspect(project, opts) do
      doc = to_doc(Playwright.Test.Project.title(project) || project.use, opts)
      concat(["#Playwright.Test.Project<", doc, ">"])
    end
  end
end
