defmodule LiveViewE2E.MixProject do
  use Mix.Project

  def project do
    [
      app: :liveview_e2e,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: [{:playwright_ex, path: "../.."}]
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["test/support"]
  defp elixirc_paths(_), do: []
end
