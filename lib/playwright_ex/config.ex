playwright_recommended_version = "1.55.0"

# styler:sort
schema_opts = [
  assets_dir: [
    default: "./assets",
    type_spec: quote(do: binary()),
    type_doc: "`t:binary/0`",
    type: {:custom, PlaywrightEx.Config, :__validate_assets_dir__, []},
    doc: """
    The directory where the JS assets are located and the Playwright CLI is installed.
    Playwright version `#{playwright_recommended_version}` or newer is recommended.
    """
  ],
  browser_launch_timeout: [
    default: to_timeout(second: 4),
    type: :non_neg_integer
  ],
  executable_path: [
    type: :string,
    doc: """
    Path to a browser executable to run instead of the bundled one.
    Use at your own risk.
    """
  ],
  js_logger: [
    default: PlaywrightEx.JsLoggerDefault,
    type: :atom,
    type_doc: "`module | false`",
    doc: "`false` to disable, or a module that implements the `PlaywrightEx.JsLogger` behaviour."
  ],
  runner: [
    default: "npx",
    type_spec: quote(do: binary()),
    type_doc: "`t:binary/0`",
    type: {:custom, PlaywrightEx.Config, :__validate_runner__, []},
    doc: """
    The JS package runner to use to run the Playwright CLI.
    Accepts either a binary executable exposed in PATH or the absolute path to it.
    """
  ],
  timeout: [
    default: to_timeout(second: 2),
    type: :non_neg_integer
  ]
]

schema = NimbleOptions.new!(schema_opts)

defmodule PlaywrightEx.Config do
  @moduledoc """
  Configuration options.

  Most should be set globally in `config/tests.exs`.

  All options:
  #{NimbleOptions.docs(schema)}
  """

  @schema schema
  @playwright_recommended_version playwright_recommended_version

  def validate!(config) when is_map(config), do: config |> Keyword.new() |> validate!()

  def validate!(config) when is_list(config) do
    global()
    |> Keyword.merge(config)
    |> NimbleOptions.validate!(@schema)
  end

  def __validate_runner__(runner) do
    if executable = System.find_executable(runner) do
      {:ok, executable}
    else
      message = """
      could not find runner executable at `#{runner}`.

      To resolve this please
      1. Install a JS package runner like `npx` or `bunx`
      2. Configure the preferred runner in `config/test.exs`, e.g.: `config :phoenix_test, playwright: [runner: "npx"]`
      3. Ensure either the runner is in your PATH or the `runner` value is a absolute path to the executable (e.g. `Path.absname("_build/bun")`)
      """

      {:error, message}
    end
  end

  def __validate_assets_dir__(assets_dir) do
    playwright_json = Path.join([assets_dir, "node_modules", "playwright", "package.json"])

    with {:ok, string} <- File.read(playwright_json),
         {:ok, json} <- JSON.decode(string) do
      version = json["version"] || "0"

      if Version.compare(version, @playwright_recommended_version) == :lt do
        IO.warn("Playwright version #{version} is below recommended #{@playwright_recommended_version}")
      end

      {:ok, assets_dir}
    else
      {:error, error} ->
        message = """
        could not find playwright in `#{assets_dir}`.
        Reason: #{inspect(error)}

        To resolve this please
        1. Install playwright, e.g. via `npm --prefix assets install playwright`
        """

        {:error, message}
    end
  end

  def __validate_cli__(_cli) do
    {:error,
     "it is deprecated. Use `assets_dir` instead if you want to customize the Playwright installation directory path and remove the `cli` option."}
  end
end
