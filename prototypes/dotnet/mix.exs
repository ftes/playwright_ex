defmodule Playwright.MixProject do
  use Mix.Project

  def project do
    [
      app: :playwright_dotnet_port,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
