defmodule PlaywrightEx.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/ftes/playwright_ex"
  @description """
  Elixir client for the Playwright node.js server.
  """

  def project do
    [
      app: :playwright_ex,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      name: "PlaywrightEx",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_options, "~> 1.1"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.3", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Github" => @source_url},
      exclude_patterns: ~w(assets/node_modules priv/static/assets)
    ]
  end

  def cli do
    [
      preferred_envs: [
        format: :test,
        setup: :test,
        check: :test,
        "assets.setup": :test
      ]
    ]
  end

  defp docs do
    [
      main: "PlaywrightEx",
      extras: [
        "CHANGELOG.md": [title: "Changelog"]
      ],
      nest_modules_by_prefix: [PlaywrightEx]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "assets.setup": [
        "cmd npm install --prefix assets",
        "cmd npm exec --prefix assets playwright -- install chromium --with-deps --only-shell"
      ],
      check: [
        "format --check-formatted",
        "credo",
        "compile --warnings-as-errors",
        "test --warnings-as-errors"
      ]
    ]
  end
end
