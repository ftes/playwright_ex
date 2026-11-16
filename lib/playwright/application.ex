defmodule Playwright.Application do
  @moduledoc false
  # Global state of the library: the table of the abort signals (`Playwright.AbortSignal`) and
  # the rows owned by processes (`Playwright.Runtime.ProcessOwner`). Drivers are started by the
  # user (`Playwright.Supervisor`).
  use Application

  @impl Application
  def start(_type, _args) do
    # A bad config fails here, not at the first test or matcher.
    validate_env!(Application.get_all_env(:playwright))
    Playwright.Driver.config()
    Playwright.Matchers.Expect.app_env_expect_config()
    Playwright.Test.Options.context_options(Playwright.Test.Options.config())
    Playwright.Test.GitHubFormatter.config()
    children = [Playwright.AbortSignal, Playwright.Runtime.ProcessOwner]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  # The keys of `config :playwright, ...` the library reads (`Playwright.Test`'s, the
  # matchers', `Playwright.Driver`'s), and the modules that read their own
  # (`Playwright.Test.GitHubFormatter`).
  @keys [:test, :expect, :driver]

  @doc false
  # Raises `ArgumentError` for a key of `env` (the app env) that is neither one of `@keys` nor a
  # module.
  def validate_env!(env) do
    case for({key, _value} <- env, key not in @keys and not module?(key), do: key) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown keys #{inspect(unknown)} in config :playwright, expected one of #{inspect(@keys)} " <>
                "or a module's (#{inspect(Playwright.Test.GitHubFormatter)})"
    end
  end

  defp module?(key), do: String.starts_with?(Atom.to_string(key), "Elixir.") and Code.ensure_loaded?(key)
end
