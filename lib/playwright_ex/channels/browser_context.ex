defmodule PlaywrightEx.BrowserContext do
  @moduledoc """
  Interact with a Playwright `BrowserContext`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/browserContext.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Creates a new page in the browser context.

  Reference: https://playwright.dev/docs/api/class-browsercontext#browser-context-new-page

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type new_page_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec new_page(PlaywrightEx.guid(), [new_page_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, %{guid: PlaywrightEx.guid(), main_frame: %{guid: PlaywrightEx.guid()}}} | {:error, any()}
  def new_page(context_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: context_id, method: :new_page, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap_create(:page, connection)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      cookies: [
        type: {:list, :any},
        required: true,
        doc: "Adds cookies into this browser context. All pages within this context will have these cookies installed."
      ]
    )

  @doc """
  Adds cookies into this browser context.

  Reference: https://playwright.dev/docs/api/class-browsercontext#browser-context-add-cookies

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type add_cookies_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec add_cookies(PlaywrightEx.guid(), [add_cookies_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def add_cookies(context_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: context_id, method: :add_cookies, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      urls: [
        type: {:list, :string},
        default: [],
        doc: "If specified, returns cookies for the given URLs."
      ]
    )

  @doc """
  Returns cookies from this browser context.

  Reference: https://playwright.dev/docs/api/class-browsercontext#browser-context-cookies

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type cookies_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec cookies(PlaywrightEx.guid(), [cookies_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, [map()]} | {:error, any()}
  def cookies(context_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: context_id, method: :cookies, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.cookies)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      domain: [
        type: :any,
        required: false,
        doc: "Only removes cookies with the given domain."
      ],
      name: [
        type: :any,
        required: false,
        doc: "Only removes cookies with the given name."
      ],
      path: [
        type: :any,
        required: false,
        doc: "Only removes cookies with the given path."
      ]
    )

  @doc """
  Removes cookies from this browser context.

  Reference: https://playwright.dev/docs/api/class-browsercontext#browser-context-clear-cookies

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type clear_cookies_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec clear_cookies(PlaywrightEx.guid(), [clear_cookies_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def clear_cookies(context_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: context_id, method: :clear_cookies, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector_engine: [
        type: :non_empty_keyword_list,
        required: true,
        keys: [
          name: [
            type: :string,
            required: true,
            doc: "Name that is used in selectors as a prefix."
          ],
          source: [
            type: :string,
            required: true,
            doc: "Script that evaluates to a selector engine instance."
          ]
        ]
      ]
    )

  @doc """
  Registers a custom selector engine.

  Reference: https://playwright.dev/docs/api/class-selectors#selectors-register

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type register_selector_engine_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec register_selector_engine(PlaywrightEx.guid(), [register_selector_engine_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def register_selector_engine(context_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    params = opts |> Map.new() |> Map.update!(:selector_engine, &Map.new/1)

    connection
    |> Connection.send(%{guid: context_id, method: :register_selector_engine, params: params}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      reason: [
        type: :string,
        required: false,
        doc: "The reason to be reported to the operations interrupted by the context closure."
      ]
    )

  @doc """
  Closes the browser context.

  Reference: https://playwright.dev/docs/api/class-browsercontext#browser-context-close

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type close_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec close(PlaywrightEx.guid(), [close_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def close(browser_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: browser_id, method: :close, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      content: [
        type: :string,
        required: true,
        doc: "Raw JavaScript code to be evaluated in all pages before any scripts run."
      ]
    )

  @doc """
  Adds a script which would be evaluated in one of the following scenarios:

  - Whenever a page is created in the browser context or is navigated.
  - Whenever a child frame is attached or navigated in any page in the browser context. In this case, the script is evaluated in the context of the newly attached frame.

  The script is evaluated after the document was created but before any of its scripts were run.
  This is useful to amend the JavaScript environment, e.g. to seed `Math.random`.

  Reference: https://playwright.dev/docs/api/class-browsercontext#browser-context-add-init-script

  > ### Script Execution Order Is Not Defined {: .info}
  >
  > The order of evaluation of multiple scripts installed via
  > `PlaywrightEx.BrowserContext.add_init_script/2` and
  > `PlaywrightEx.Page.add_init_script/2` is not defined.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type add_init_script_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec add_init_script(PlaywrightEx.guid(), [add_init_script_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def add_init_script(context_id, opts \\ []) do
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: context_id, method: :addInitScript, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
