defmodule PlaywrightEx.Page do
  @moduledoc """
  Interact with a Playwright `Page`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/page.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      event: [type: :atom, required: true],
      enabled: [type: :boolean, default: true]
    )

  @doc """
  Updates the subscription for page events.

  Reference: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/page.ts

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type update_subscription_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec update_subscription(PlaywrightEx.guid(), [update_subscription_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def update_subscription(page_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: page_id, method: :update_subscription, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      full_page: [
        type: :boolean,
        doc:
          "When true, takes a screenshot of the full scrollable page, instead of the currently visible viewport. Defaults to `false`."
      ],
      omit_background: [
        type: :boolean,
        doc:
          "Hides default white background and allows capturing screenshots with transparency. Defaults to `false`. Not applicable to jpeg images."
      ]
    )

  @doc """
  Returns a screenshot of the page as binary data.

  Reference: https://playwright.dev/docs/api/class-page#page-screenshot

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type screenshot_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec screenshot(PlaywrightEx.guid(), [screenshot_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, binary()} | {:error, any()}
  def screenshot(page_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: page_id, method: :screenshot, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1.binary)
  end
end
