defmodule PlaywrightEx.Dialog do
  @moduledoc """
  Interact with a Playwright `Dialog`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/dialog.ts
  """

  import PlaywrightEx.Connection, only: [post: 1]

  alias PlaywrightEx.Result

  def accept(dialog_id, opts \\ []) do
    [guid: dialog_id, method: :accept, params: Map.new(opts)]
    |> post()
    |> Result.from_response(& &1)
  end

  def dismiss(dialog_id, opts \\ []) do
    [guid: dialog_id, method: :dismiss, params: Map.new(opts)]
    |> post()
    |> Result.from_response(& &1)
  end
end
