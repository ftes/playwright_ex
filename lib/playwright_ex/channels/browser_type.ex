defmodule PlaywrightEx.BrowserType do
  @moduledoc """
  Interact with a Playwright `BrowserType`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/browserType.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  @type guid :: String.t()

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      channel: [
        type: :string,
        doc: "Browser distribution channel."
      ],
      executable_path: [
        type: :string,
        doc: "Path to a browser executable to run instead of the bundled one."
      ],
      headless: [
        type: :boolean,
        doc: "Whether to run browser in headless mode."
      ],
      slow_mo: [
        type: {:or, [:integer, :float]},
        doc: "Slows down Playwright operations by the specified amount of milliseconds."
      ]
    )

  @doc """
  Launches a new browser instance.

  Reference: https://playwright.dev/docs/api/class-browsertype#browser-type-launch

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type launch_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec launch(PlaywrightEx.guid(), [launch_opt() | {Keyword.key(), any()}]) ::
          {:ok, %{guid: PlaywrightEx.guid()}} | {:error, any()}
  def launch(type_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: type_id, method: :launch, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap_create(:browser)
  end
end
