defmodule PlaywrightEx.Application do
  @moduledoc false
  # Global state of the library: the table of the abort signals (`PlaywrightEx.AbortSignal`) and
  # the rows owned by processes (`PlaywrightEx.Runtime.ProcessOwner`). Drivers are started by the
  # user (`PlaywrightEx.Supervisor`).
  use Application

  @impl Application
  def start(_type, _args) do
    # A bad config fails here, not at the first test or matcher.
    validate_env!(Application.get_all_env(:playwright_ex))
    PlaywrightEx.Matchers.Expect.app_env_expect_config()
    PlaywrightEx.Test.Options.context_options(PlaywrightEx.Test.Options.config())
    PlaywrightEx.Test.GitHubFormatter.config()
    children = [PlaywrightEx.AbortSignal, PlaywrightEx.Runtime.ProcessOwner]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  # The keys of `config :playwright_ex, ...` the library reads (`PlaywrightEx.Test`'s, the
  # matchers'), and the modules that read their own (`PlaywrightEx.Test.GitHubFormatter`).
  @keys [:test, :expect]

  @doc false
  # Raises `ArgumentError` for a key of `env` (the app env) that is neither one of `@keys` nor a
  # module.
  def validate_env!(env) do
    case for({key, _value} <- env, key not in @keys and not module?(key), do: key) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown keys #{inspect(unknown)} in config :playwright_ex, expected one of #{inspect(@keys)} " <>
                "or a module's (#{inspect(PlaywrightEx.Test.GitHubFormatter)})"
    end
  end

  defp module?(key), do: String.starts_with?(Atom.to_string(key), "Elixir.") and Code.ensure_loaded?(key)
end
