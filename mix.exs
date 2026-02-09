defmodule PlaywrightEx.MixProject do
  use Mix.Project

  @version "0.4.0"
  @source_url "https://github.com/ftes/playwright_ex"
  @description """
  Elixir client for the Playwright node.js driver.
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
      aliases: aliases(),
      dialyzer: [
        plt_local_path: "priv/plts/project.plt",
        plt_core_path: "priv/plts/core.plt",
        plt_add_apps: [:ex_unit, :mix]
        # flags: [:specdiffs]
      ]
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
      {:websockex, "~> 0.4", optional: true},
      {:testcontainers, "~> 1.11", only: :test},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.3", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Github" => @source_url},
      exclude_patterns: ~w(assets/node_modules priv/static/assets priv/plts)
    ]
  end

  def cli do
    [
      preferred_envs: [
        format: :test,
        setup: :test,
        check: :test,
        "assets.setup": :test,
        "test.websocket": :test
      ]
    ]
  end

  defp docs do
    [
      main: "PlaywrightEx",
      source_ref: "v#{@version}",
      extras: [
        "CHANGELOG.md": [title: "Changelog"]
      ],
      nest_modules_by_prefix: [PlaywrightEx],
      filter_modules: fn _, metadata ->
        not String.contains?(to_string(metadata.source_path), "/processes/")
      end,
      groups_for_modules: [
        Channels:
          if File.exists?("lib") do
            for file <- File.ls!("lib/playwright_ex/channels") do
              "PlaywrightEx.#{file |> Path.basename(".ex") |> Macro.camelize()}"
            end
          end,
        Other: [PlaywrightEx.JsLogger, PlaywrightEx.Supervisor]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "assets.setup": [
        "cmd npm install --prefix assets",
        "cmd npm exec --prefix assets playwright -- install chromium --with-deps --only-shell"
      ],
      "test.websocket": "playwright_ex.test.websocket",
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
