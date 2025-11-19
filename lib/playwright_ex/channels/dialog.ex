defmodule PlaywrightEx.Dialog do
  @moduledoc """
  Interact with a Playwright `Dialog`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/dialog.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  @type guid :: String.t()

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      prompt_text: [
        type: :string,
        doc: "A text to enter in prompt. Does not cause any effects if the dialog's type is not prompt."
      ]
    )

  @doc """
  Returns when the dialog has been accepted.

  Reference: https://playwright.dev/docs/api/class-dialog#dialog-accept

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type accept_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec accept(PlaywrightEx.guid(), [accept_opt() | {Keyword.key(), any()}]) :: {:ok, any()} | {:error, any()}
  def accept(dialog_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: dialog_id, method: :accept, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(timeout: PlaywrightEx.Channel.timeout_opt())

  @doc """
  Returns when the dialog has been dismissed.

  Reference: https://playwright.dev/docs/api/class-dialog#dialog-dismiss

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type dismiss_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec dismiss(PlaywrightEx.guid(), [dismiss_opt() | {Keyword.key(), any()}]) :: {:ok, any()} | {:error, any()}
  def dismiss(dialog_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: dialog_id, method: :dismiss, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
