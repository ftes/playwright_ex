defmodule PlaywrightEx.Browser do
  @moduledoc """
  Interact with a Playwright `Browser`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/browser.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      accept_downloads: [
        type: :boolean,
        doc: "Whether to automatically download all the attachments. Defaults to `true`."
      ],
      base_url: [
        type: :string,
        doc:
          "When using `Page.goto/3`, `Page.route/3`, `Page.wait_for_url/3`, etc., it takes the base URL into consideration."
      ],
      bypass_csp: [
        type: :boolean,
        doc: "Toggles bypassing page's Content-Security-Policy. Defaults to `false`."
      ],
      color_scheme: [
        type: {:in, [:light, :dark, :no_preference, :null]},
        doc: "Emulates `'prefers-colors-scheme'` media feature. Defaults to `:light`."
      ],
      device_scale_factor: [
        type: :float,
        doc: "Specify device scale factor (can be thought of as dpr). Defaults to `1`."
      ],
      extra_http_headers: [
        type: :any,
        doc: "An object containing additional HTTP headers to be sent with every request."
      ],
      http_credentials: [
        type: :any,
        doc: "Credentials for HTTP authentication. Map with `:username` and `:password`."
      ],
      ignore_https_errors: [
        type: :boolean,
        doc: "Whether to ignore HTTPS errors when sending network requests. Defaults to `false`."
      ],
      is_mobile: [
        type: :boolean,
        doc: "Whether the meta viewport tag is taken into account and touch events are enabled. Defaults to `false`."
      ],
      java_script_enabled: [
        type: :boolean,
        doc: "Whether or not to enable JavaScript in the context. Defaults to `true`."
      ],
      locale: [
        type: :string,
        doc: "Specify user locale, for example `en-GB`, `de-DE`, etc."
      ],
      user_agent: [
        type: :string,
        doc: "Specific user agent to use in this context."
      ],
      viewport: [
        type: :any,
        doc: "Sets a consistent viewport for each page. Map with `:width` and `:height`, or `nil` to disable."
      ]
    )

  @doc """
  Creates a new browser context. It won't share cookies/cache with other browser contexts.

  Reference: https://playwright.dev/docs/api/class-browser#browser-new-context

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type new_context_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec new_context(PlaywrightEx.guid(), [new_context_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid(), tracing: %{guid: PlaywrightEx.guid()}}} | {:error, any()}
  def new_context(browser_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: browser_id, method: :new_context, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap_create(:context)
  end

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      reason: [
        type: :string,
        doc: "The reason to be reported to the operations interrupted by the browser closure."
      ]
    )

  @doc """
  Closes the browser and all of its contexts.

  Reference: https://playwright.dev/docs/api/class-browser#browser-close

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type close_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec close(PlaywrightEx.guid(), [close_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def close(browser_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: browser_id, method: :close, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
