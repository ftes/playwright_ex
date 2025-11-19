defmodule PlaywrightEx.BrowserType do
  @moduledoc """
  Interact with a Playwright `BrowserType`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/browserType.ts
  """

  import PlaywrightEx.Connection, only: [post: 2]
  import PlaywrightEx.Result, only: [from_response: 2]

  def launch(type_id, opts \\ []) do
    %{guid: type_id, method: :launch, params: Map.new(opts)}
    |> post(opts[:timeout])
    |> from_response(& &1.result.browser.guid)
  end
end
