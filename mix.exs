defmodule Playwright.MixProject do
  use Mix.Project

  @version "1.65.0-rc.2"
  @source_url "https://github.com/ftes/playwright_ex"
  @description """
  Elixir client for Playwright: a port of the official JavaScript client.
  """

  def project do
    [
      app: :playwright,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      name: "Playwright",
      source_url: @source_url,
      docs: docs(),
      aliases: aliases(),
      usage_rules: usage_rules(),
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
      mod: {Playwright.Application, []},
      # inets/ssl/public_key: driver download (`Playwright.Driver`). No ex_unit, which
      # `Playwright.Test` calls: listed (even `:optional`), it would ship in releases and start.
      extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]
    ]
  end

  # dev/: maintainer tooling (generators, parity, checksums, `Playwright.Upstream`), not in the package.
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(:test), do: ["lib", "test/support", "dev"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.39.0 and < 1.0.0", only: [:dev, :test], runtime: false},
      {:usage_rules, "~> 1.3", only: [:dev, :test], runtime: false},
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
      # The Hex package keeps its name: `playwright` on Hex is another library.
      name: "playwright_ex",
      # The port is Apache-2.0 (Playwright's, `NOTICE`).
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url, "Changelog" => "https://hexdocs.pm/playwright_ex/#{@version}/changelog.html"},
      # Hex's default files, plus `usage-rules.md` for `mix usage_rules.sync`, the pinned versions
      # `Playwright.Driver` reads when compiling, and the licenses and notices.
      files:
        ~w(lib priv .formatter.exs mix.exs README.md usage-rules.md LICENSE NOTICE CHANGELOG.md DRIVER_VERSION NODE_VERSION),
      exclude_patterns: ~w(priv/plts)
    ]
  end

  def cli do
    [
      preferred_envs: [
        format: :test,
        setup: :test,
        check: :test,
        lint: :test
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
        "guides/introduction/whats-ported.md": [title: "What's ported"],
        "guides/introduction/api-conventions.md": [title: "From playwright.dev to Elixir"],
        "guides/introduction/cheatsheet.cheatmd": [title: "Cheatsheet"],
        "guides/testing-with-exunit.md": [title: "Testing with ExUnit"],
        "guides/test-options.md": [title: "Options, devices and projects"],
        "guides/test-artifacts.md": [title: "Artifacts, retries and workers"],
        "guides/porting-playwright-test.md": [title: "Porting Playwright Test specs"],
        "guides/events-and-waiting.md": [title: "Events and waiting"],
        "guides/network.md": [title: "Network"],
        "guides/debugging-and-ci.md": [title: "Debugging and CI"],
        "guides/concurrency.md": [title: "Concurrency"],
        "CHANGELOG.md": [title: "Changelog"]
      ],
      groups_for_extras: [
        Introduction: ["README.md", ~r"^guides/introduction/"],
        Guides: [
          "guides/testing-with-exunit.md",
          "guides/test-options.md",
          "guides/test-artifacts.md",
          "guides/porting-playwright-test.md",
          "guides/events-and-waiting.md",
          "guides/network.md",
          "guides/debugging-and-ci.md",
          "guides/concurrency.md"
        ],
        Changelog: ["CHANGELOG.md"]
      ],
      nest_modules_by_prefix: [Playwright],
      # The changelog names functions of the API before the restructure.
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      # ExUnit hides its formatter modules from its docs.
      skip_code_autolink_to: ["ExUnit.CLIFormatter"],
      # Internals keep their moduledocs (read in the source; docs/architecture.md) but stay out of
      # hexdocs: the user API is the generated facade, the errors and the runtime entry points.
      filter_modules: fn _, metadata -> not internal_source?(to_string(metadata.source_path)) end,
      # playwright.dev's API sidebar, roughly; internals are filtered out above.
      groups_for_modules: [
        Core: [
          Playwright,
          Playwright.Supervisor,
          Playwright.Driver,
          Playwright.Promise,
          Playwright.BrowserType,
          Playwright.Browser,
          Playwright.BrowserContext,
          Playwright.Selectors,
          Playwright.Clock,
          Playwright.Credentials,
          Playwright.Disposable,
          Playwright.RegExp,
          Playwright.AbortController,
          Playwright.AbortSignal
        ],
        Pages: [
          Playwright.Page,
          Playwright.Frame,
          Playwright.Locator,
          Playwright.FrameLocator,
          Playwright.ElementHandle,
          Playwright.JSHandle,
          Playwright.Keyboard,
          Playwright.Mouse,
          Playwright.Touchscreen,
          Playwright.Dialog,
          Playwright.Download,
          Playwright.FileChooser,
          Playwright.ConsoleMessage,
          Playwright.WebError,
          Playwright.WebStorage,
          Playwright.WebMCP,
          Playwright.Worker
        ],
        Assertions: [Playwright.Expect, Playwright.ExpectError],
        Testing: [
          Playwright.Case,
          Playwright.Test,
          Playwright.Test.Assertions,
          Playwright.Test.BrowserPool,
          Playwright.Test.Project,
          Playwright.Test.GitHubFormatter
        ],
        Network: [
          Playwright.Request,
          Playwright.Response,
          Playwright.Route,
          Playwright.WebSocket,
          Playwright.WebSocketRoute,
          Playwright.APIRequest,
          Playwright.APIRequestContext,
          Playwright.APIResponse
        ],
        "Artifacts and debugging": [
          Playwright.Tracing,
          Playwright.Video,
          Playwright.Screencast,
          Playwright.Coverage,
          Playwright.CDPSession,
          Playwright.Debugger
        ],
        Errors: [
          Playwright.PlaywrightError,
          Playwright.TimeoutError,
          Playwright.TargetClosedError,
          Playwright.AbortError,
          Playwright.AggregateError
        ]
      ]
    ]
  end

  # Internals, the maintainer tooling (dev/) and the test support (test/support, compiled in
  # :test): in the source with their moduledocs, not in hexdocs. All of dev/ and test/, at any
  # depth, by the path relative to this project, so a parent directory named dev (say
  # ~/dev/playwright_ex) can't match; a _build compiled at another absolute path than `mix docs`
  # runs from would show them. The lib/ internals by the end of the source path, down to the file
  # name, for the same reason.
  defp internal_source?(path) do
    String.starts_with?(Path.relative_to(path, __DIR__), ["dev/", "test/"]) or
      Enum.any?(
        [
          ~r"/lib/playwright/(client|matchers|protocol|runtime|transport|isomorphic)/[^/]+\.ex$",
          ~r"/lib/playwright/out_of_process\.ex$"
        ],
        &(path =~ &1)
      )
  end

  # `mix usage_rules.sync --yes` writes these skills to `.agents/skills` (`.claude/skills` links
  # there). Without the package's elixir and otp sub-rules: ported code follows PORTING.md instead
  # (`is_connected`, raising for control flow).
  defp usage_rules do
    [
      skills: [
        location: ".agents/skills",
        build: [
          "usage-rules": [
            description:
              "Use when looking up docs for Elixir, OTP or a dependency: `mix usage_rules.docs` and `mix usage_rules.search_docs`.",
            usage_rules: [{:usage_rules, sub_rules: []}]
          ]
        ]
      ]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "playwright.install chromium", "playwright.upstream"],
      # What CI's build job runs (`mix lint`); `check` adds the parity check and the tests.
      lint: [
        "format --check-formatted",
        "credo",
        "compile --warnings-as-errors",
        "usage_rules.sync --check",
        # As a Hex install does: from the package's files only (DRIVER_VERSION etc. are read when
        # compiling). Under the checkout, so mise's .tool-versions applies; removed first, so a
        # stale file of an earlier build can't hide a missing one in `package/0`'s files. A
        # subprocess: after `compile`, a task of the Hex archive is no longer found.
        "cmd rm -rf tmp/hex-package",
        "cmd mix hex.build --unpack --output tmp/hex-package",
        "cmd --cd tmp/hex-package env MIX_ENV=prod mix compile --warnings-as-errors",
        "docs --warnings-as-errors",
        "dialyzer --format github --format dialyxir"
      ],
      check: ["lint", "playwright.parity", "test --warnings-as-errors"]
    ]
  end
end
