defmodule PlaywrightEx.MixProject do
  use Mix.Project

  @version "0.16.0"
  @source_url "https://github.com/ftes/playwright_ex"
  @description """
  Elixir client for Playwright: a port of the official JavaScript client.
  """

  def project do
    [
      app: :playwright_ex,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      deps: deps(),
      package: package(),
      name: "PlaywrightEx",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:ex_unit, :mix]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # inets/ssl/public_key: driver download (`PlaywrightEx.Driver`).
      extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.39.0 and < 1.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.3", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Github" => @source_url},
      exclude_patterns: ~w(priv/plts)
    ]
  end

  def cli do
    [
      preferred_envs: [
        format: :test,
        setup: :test,
        check: :test
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md": [title: "Overview"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      nest_modules_by_prefix: [PlaywrightEx],
      groups_for_modules: [
        Client: ~r/^PlaywrightEx\.Client\./,
        Protocol: ~r/^PlaywrightEx\.Protocol\./,
        Runtime: ~r/^PlaywrightEx\.(Runtime|Transport)\./
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "playwright_ex.install"],
      check: [
        "format --check-formatted",
        "credo",
        "compile --warnings-as-errors",
        "dialyzer --format github --format dialyxir",
        "test --warnings-as-errors"
      ]
    ]
  end
end
