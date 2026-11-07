defmodule PlaywrightEx.MixProject do
  use Mix.Project

  @version "0.17.0-rc.0"
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
      elixirc_paths: elixirc_paths(Mix.env()),
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
      mod: {PlaywrightEx.Application, []},
      # inets/ssl/public_key: driver download (`PlaywrightEx.Driver`).
      extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]
    ]
  end

  # dev/: maintainer tooling (generators, parity, checksums, `PlaywrightEx.Upstream`), not in the package.
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(:test), do: ["lib", "test/support", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.39.0 and < 1.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      # The port of upstream tests/config/testserver.
      {:bandit, "~> 1.6", only: :test},
      # RFC 6455 framing of TestServer.WebSocket (`cow_ws`).
      {:cowlib, "~> 2.21", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"Github" => @source_url},
      # Hex's default files, plus the pinned versions `PlaywrightEx.Driver` reads when compiling.
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE.md CHANGELOG.md DRIVER_VERSION NODE_VERSION),
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
      extra_section: "GUIDES",
      extras: [
        "README.md": [title: "Overview"],
        "guides/introduction/getting-started.md": [title: "Getting started"],
        "guides/introduction/api-conventions.md": [title: "From playwright.dev to Elixir"],
        "guides/introduction/cheatsheet.cheatmd": [title: "Cheatsheet"],
        "guides/testing-with-exunit.md": [title: "Testing with ExUnit"],
        "guides/events-and-waiting.md": [title: "Events and waiting"],
        "guides/network.md": [title: "Network"],
        "guides/debugging-and-ci.md": [title: "Debugging and CI"],
        "guides/concurrency.md": [title: "Concurrency"],
        "guides/migration.md": [title: "Migrating from 0.16"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Introduction: ["README.md", ~r"^guides/introduction/"],
        Guides: [
          "guides/testing-with-exunit.md",
          "guides/events-and-waiting.md",
          "guides/network.md",
          "guides/debugging-and-ci.md",
          "guides/concurrency.md"
        ],
        Upgrading: ["guides/migration.md", "CHANGELOG.md"]
      ],
      nest_modules_by_prefix: [PlaywrightEx],
      # The changelog names functions of the API before the restructure.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      # Internals keep their moduledocs (read in the source; docs/architecture.md) but stay out of
      # hexdocs: the user API is the generated facade, the errors and the runtime entry points.
      filter_modules: fn _, metadata -> not internal_source?(to_string(metadata.source_path)) end,
      # playwright.dev's API sidebar, roughly; internals are filtered out above.
      groups_for_modules: [
        Core: [
          PlaywrightEx,
          PlaywrightEx.Supervisor,
          PlaywrightEx.Driver,
          PlaywrightEx.Promise,
          PlaywrightEx.Playwright,
          PlaywrightEx.BrowserType,
          PlaywrightEx.Browser,
          PlaywrightEx.BrowserContext,
          PlaywrightEx.Selectors,
          PlaywrightEx.Clock,
          PlaywrightEx.Credentials,
          PlaywrightEx.Disposable,
          PlaywrightEx.RegExp,
          PlaywrightEx.AbortController,
          PlaywrightEx.AbortSignal
        ],
        Pages: [
          PlaywrightEx.Page,
          PlaywrightEx.Frame,
          PlaywrightEx.Locator,
          PlaywrightEx.FrameLocator,
          PlaywrightEx.ElementHandle,
          PlaywrightEx.JSHandle,
          PlaywrightEx.Keyboard,
          PlaywrightEx.Mouse,
          PlaywrightEx.Touchscreen,
          PlaywrightEx.Dialog,
          PlaywrightEx.Download,
          PlaywrightEx.FileChooser,
          PlaywrightEx.ConsoleMessage,
          PlaywrightEx.WebError,
          PlaywrightEx.WebStorage,
          PlaywrightEx.WebMCP,
          PlaywrightEx.Worker
        ],
        Assertions: [PlaywrightEx.Expect, PlaywrightEx.ExpectError],
        Network: [
          PlaywrightEx.Request,
          PlaywrightEx.Response,
          PlaywrightEx.Route,
          PlaywrightEx.WebSocket,
          PlaywrightEx.WebSocketRoute,
          PlaywrightEx.APIRequest,
          PlaywrightEx.APIRequestContext,
          PlaywrightEx.APIResponse
        ],
        "Artifacts and debugging": [
          PlaywrightEx.Tracing,
          PlaywrightEx.Video,
          PlaywrightEx.Screencast,
          PlaywrightEx.Coverage,
          PlaywrightEx.CDPSession,
          PlaywrightEx.Debugger
        ],
        Errors: [
          PlaywrightEx.PlaywrightError,
          PlaywrightEx.TimeoutError,
          PlaywrightEx.TargetClosedError,
          PlaywrightEx.AbortError
        ]
      ]
    ]
  end

  # Internals and the maintainer tooling (dev/, compiled in :dev): in the source with their
  # moduledocs, not in hexdocs.
  defp internal_source?(path) do
    String.starts_with?(Path.relative_to(path, __DIR__), "dev/") or
      Enum.any?(
        [
          ~r"/lib/playwright_ex/(client|matchers|protocol|runtime|transport|isomorphic)/",
          ~r"/lib/playwright_ex/out_of_process\.ex$"
        ],
        &(path =~ &1)
      )
  end

  defp aliases do
    [
      setup: ["deps.get", "playwright_ex.install -- chromium"],
      check: [
        "format --check-formatted",
        "credo",
        "compile --warnings-as-errors",
        "dialyzer --format github --format dialyxir",
        "playwright_ex.parity",
        "test --warnings-as-errors"
      ]
    ]
  end
end
