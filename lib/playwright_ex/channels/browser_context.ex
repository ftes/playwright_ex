defmodule PlaywrightEx.BrowserContext do
  @moduledoc """
  Interact with a Playwright `BrowserContext`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/browserContext.ts
  """

  import PlaywrightEx.Connection, only: [post: 2]
  import PlaywrightEx.Result, only: [from_response: 2]

  def new_page(context_id, opts \\ []) do
    params = Map.new(opts)

    %{guid: context_id, method: :new_page, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1.result.page.guid)
  end

  def add_cookies(context_id, cookies, opts \\ []) do
    params = Enum.into(opts, %{cookies: cookies})

    %{guid: context_id, method: :add_cookies, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def clear_cookies(context_id, opts \\ []) do
    opts = Keyword.validate!(opts, ~w(domain name path)a)

    %{guid: context_id, method: :clear_cookies, params: Map.new(opts)}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def register_selector_engine(context_id, name, source, opts \\ []) do
    params = %{selector_engine: Enum.into(opts, %{name: name, source: source})}

    %{guid: context_id, method: :register_selector_engine, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end

  def close(browser_id, opts \\ []) do
    params = Map.new(opts)

    %{guid: browser_id, method: :close, params: params}
    |> post(opts[:timeout])
    |> from_response(& &1)
  end
end
