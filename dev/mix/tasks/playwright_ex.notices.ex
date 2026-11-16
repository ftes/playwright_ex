defmodule Mix.Tasks.PlaywrightEx.Notices do
  @shortdoc "Writes the copyright headers of the files derived from upstream"
  @moduledoc """
  Puts each file derived from upstream under its upstream files' copyright header
  (`Mix.PlaywrightEx.Notices`), replacing the one it has, and drops the header of a file that
  no longer derives from upstream. Idempotent. Generated files are left to their generators.

      mix playwright_ex.notices [<playwright-repo>]

  `mix playwright_ex.parity` fails on a file whose header is out of date.
  """
  use Mix.Task

  alias Mix.PlaywrightEx.Notices

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

  def run(_), do: Mix.raise("Usage: mix playwright_ex.notices [<playwright-repo>]")
end
