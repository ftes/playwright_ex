defmodule Mix.Tasks.Playwright.Notices do
  @shortdoc "Writes the copyright headers of the files derived from upstream"
  @moduledoc """
  Puts each file derived from upstream under its upstream files' copyright header
  (`Mix.Playwright.Notices`), replacing the one it has, and drops the header of a file that
  no longer derives from upstream. Idempotent. Generated files are left to their generators.

      mix playwright.notices [<playwright-repo>]

  `mix playwright.parity` fails on a file whose header is out of date.
  """
  use Mix.Task

  alias Mix.Playwright.Notices

  @impl Mix.Task
  def run([]), do: run([Playwright.Upstream.ensure!()])

  def run([upstream]) do
    for path <- Notices.files(),
        source <- [File.read!(path)],
        not Notices.generated?(source),
        new <- [Notices.put(upstream, path, source)],
        new != source do
      File.write!(path, new)
      Mix.shell().info("Wrote #{path}")
    end

    :ok
  end

  def run(_), do: Mix.raise("Usage: mix playwright.notices [<playwright-repo>]")
end
