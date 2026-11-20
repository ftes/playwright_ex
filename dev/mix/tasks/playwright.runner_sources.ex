defmodule Mix.Tasks.Playwright.RunnerSources do
  @shortdoc "Prints the upstream runner files a version bump diffs"
  @moduledoc """
  Usage: `mix playwright.runner_sources`

  Prints `Mix.Playwright.Notices.runner_sources/0` on one line, space-separated: the upstream
  Playwright Test files `Playwright.Test` derives from or follows, for a bump's
  `git diff vA vB -- $(mix playwright.runner_sources)` (PORTING.md, "Bumping the pinned
  version"). `mix playwright.parity` fails on a runner citation the list lacks.
  """
  use Mix.Task

  @impl Mix.Task
  def run([]), do: Mix.shell().info(Enum.join(Mix.Playwright.Notices.runner_sources(), " "))
  def run(_), do: Mix.raise("Usage: mix playwright.runner_sources")
end
