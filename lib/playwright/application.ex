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
    children = [Playwright.AbortSignal, Playwright.Runtime.ProcessOwner]
    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  # The keys of `config :playwright, ...` the library reads: `Playwright.Test`'s, the
  # matchers', `Playwright.Driver`'s.
  @keys [:test, :expect, :driver]

  @doc false
  # Raises `ArgumentError` for a key of `env` (the app env) that is not one of `@keys`.
  def validate_env!(env) do
    keys!("config :playwright", env, @keys)
    :ok
  end

  @doc false
  # `config :playwright, key` (`env`, by default the app env's, `[]` when unset), checked: a
  # keyword list of `allowed` keys, else `ArgumentError`. Each reader validates the values.
  def config!(key, allowed, env \\ nil),
    do: keys!("config :playwright, #{inspect(key)}", env || Application.get_env(:playwright, key, []), allowed)

  defp keys!(label, env, allowed) do
    if !(is_list(env) and Keyword.keyword?(env)),
      do: raise(ArgumentError, "#{label}: expected a keyword list, got: #{inspect(env)}")

    case Keyword.keys(env) -- allowed do
      [] ->
        env

      unknown ->
        raise ArgumentError, "#{label}: unknown keys, expected one of #{inspect(allowed)}, got: #{inspect(unknown)}"
    end
  end
end
