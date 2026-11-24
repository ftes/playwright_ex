# This repo's settings for ftes/ci's release script (scripts/release fetches it); its header
# documents each key.
defmodule ReleaseScript.Config do
  @moduledoc false

  def config do
    %{
      repo: "ftes/playwright_ex",
      # `RELEASE_REMOTE` names another remote than origin.
      remote: System.get_env("RELEASE_REMOTE", "origin"),
      branch: "main",
      # Its publish job releases a pushed `v*` tag once the tests passed.
      workflow: "elixir.yml",
      hex_package: "playwright_ex",
      snippets: [
        {"README.md", ~r/\{:playwright, "~> ([^"]+)", hex: :playwright_ex\}/},
        {"guides/upgrading-from-0.x.md", ~r/\{:playwright, "~> ([^"]+)", hex: :playwright_ex\}/}
      ],
      driver_line: true,
      driver_minor: true,
      minor_requirement: true,
      changelog: %{
        unreleased: "## [Unreleased]",
        version_prefix: "## [",
        version_suffix: "]",
        date_separator: " ",
        reopen_prereleases: false,
        rc_only: "**RC only:**"
      }
    }
  end
end
