defmodule PlaywrightEx.Page do
  @moduledoc """
  Interact with a Playwright `Page`.

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/page.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Serialization

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
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
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: page_id, method: :update_subscription, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      wait_until: [
        type: {:in, [:load, :domcontentloaded, :networkidle, :commit]},
        doc: "When to consider operation succeeded, defaults to `load`."
      ]
    )

  @doc """
  Reloads the page.

  Reference: https://playwright.dev/docs/api/class-page#page-reload

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type reload_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec reload(PlaywrightEx.guid(), [reload_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def reload(page_id, opts \\ []) do
    {connection, opts} =
      opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)

    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: page_id, method: :reload, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
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
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: page_id, method: :screenshot, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.binary)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      x: [
        type: {:or, [:integer, :float]},
        required: true,
        doc: "`x` coordinate relative to the main frame's viewport in CSS pixels."
      ],
      y: [
        type: {:or, [:integer, :float]},
        required: true,
        doc: "`y` coordinate relative to the main frame's viewport in CSS pixels."
      ]
    )

  @doc """
  Moves the mouse to the specified coordinates.

  This method dispatches a `mousemove` event. Supports fractional coordinates for precise positioning.

  Reference: https://playwright.dev/docs/api/class-mouse#mouse-move

  ## Example

      # Get element position
      {:ok, result} = Frame.evaluate(frame_id,
        expression: "() => {
          const el = document.querySelector('.slider-handle');
          const box = el.getBoundingClientRect();
          return { x: box.x + box.width / 2, y: box.y + box.height / 2 };
        }",
        is_function: true,
        timeout: 5000
      )

      # Move to element
      {:ok, _} = Page.mouse_move(page_id, x: result["x"], y: result["y"], timeout: 5000)

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type mouse_move_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec mouse_move(PlaywrightEx.guid(), [mouse_move_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def mouse_move(page_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: page_id, method: :mouseMove, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      button: [
        type: {:in, [:left, :right, :middle]},
        default: :left,
        doc: "Defaults to `:left`."
      ]
    )

  @doc """
  Dispatches a `mousedown` event at the current mouse position.

  Reference: https://playwright.dev/docs/api/class-mouse#mouse-down

  ## Example

      # Perform a manual drag operation
      {:ok, _} = Page.mouse_move(page_id, x: 100, y: 100, timeout: 5000)
      {:ok, _} = Page.mouse_down(page_id, timeout: 5000)
      {:ok, _} = Page.mouse_move(page_id, x: 200, y: 100, timeout: 5000)
      {:ok, _} = Page.mouse_up(page_id, timeout: 5000)

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type mouse_down_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec mouse_down(PlaywrightEx.guid(), [mouse_down_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def mouse_down(page_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: page_id, method: :mouseDown, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      button: [
        type: {:in, [:left, :right, :middle]},
        default: :left,
        doc: "Defaults to `:left`."
      ]
    )

  @doc """
  Dispatches a `mouseup` event at the current mouse position.

  Reference: https://playwright.dev/docs/api/class-mouse#mouse-up

  ## Example

      # Right-click at current position
      {:ok, _} = Page.mouse_down(page_id, button: :right, timeout: 5000)
      {:ok, _} = Page.mouse_up(page_id, button: :right, timeout: 5000)

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type mouse_up_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec mouse_up(PlaywrightEx.guid(), [mouse_up_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def mouse_up(page_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: page_id, method: :mouseUp, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      url: [
        type: {:or, [:string, {:struct, Regex}, {:fun, 1}]},
        required: true,
        doc: "Expected URL as a string, `Regex`, or predicate function `fn URI.t() -> boolean end`."
      ],
      is_not: [
        type: :boolean,
        default: false,
        doc: "Whether to negate the expectation."
      ],
      ignore_case: [
        type: :boolean,
        default: false,
        doc: "Whether URL comparison should ignore case."
      ]
    )

  @doc group: :composed
  @doc """
  Expects page URL to match the provided expectation.

  This library exposes URL assertions as `Page.expect_url/2`.

  In the official Playwright JavaScript API, URL assertions are written as
  `await expect(page).toHaveURL(...)`. That matcher API is not exposed here.

  Matching strategy:
  - String/`Regex`: delegates to `PlaywrightEx.Frame.expect/2` with expression `"to.have.url"`, which uses server-side
    assertion polling (`is_not` is passed through for retry semantics).
  - Predicate function: delegates to `PlaywrightEx.Frame.wait_for_url/2`, which is navigation-event based
    (waits on `:navigated` + lifecycle events rather than polling page JavaScript).

  Returns `true` when the expectation is satisfied and `false` otherwise.

  Reference: https://playwright.dev/docs/api/class-pageassertions#page-assertions-to-have-url

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type expect_url_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec expect_url(PlaywrightEx.guid(), [expect_url_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, boolean()} | {:error, any()}
  def expect_url(page_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)
    url_expectation = Keyword.fetch!(opts, :url)
    is_not? = Keyword.fetch!(opts, :is_not)
    ignore_case? = Keyword.fetch!(opts, :ignore_case)
    frame_id = main_frame_id!(connection, page_id)

    if is_function(url_expectation, 1) do
      expect_url_with_predicate(frame_id, url_expectation, is_not?, ignore_case?, timeout, connection)
    else
      expect_url_with_text_matcher(frame_id, url_expectation, is_not?, ignore_case?, timeout, connection)
    end
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      source: [
        type: :string,
        required: true,
        doc: "Raw JavaScript code to be evaluated in all pages before any scripts run."
      ]
    )

  @doc """
  Adds a script which would be evaluated in one of the following scenarios:

  - Whenever the page is navigated.
  - Whenever the child frame is attached or navigated. In this case, the script is evaluated in the context of the newly attached frame.

  The script is evaluated after the document was created but before any of its scripts were run.
  This is useful to amend the JavaScript environment, e.g. to seed `Math.random`.

  Reference: https://playwright.dev/docs/api/class-page#page-add-init-script

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
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: context_id, method: :addInitScript, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  defp main_frame_id!(connection, page_id) do
    page_initializer = Connection.initializer!(connection, page_id)
    page_initializer.main_frame.guid
  end

  defp expect_url_with_predicate(frame_id, predicate, is_not?, ignore_case?, timeout, connection) do
    matcher = fn uri ->
      uri = maybe_downcase_uri(uri, ignore_case?)
      matches? = predicate.(uri)
      matches? != is_not?
    end

    case Frame.wait_for_url(frame_id, connection: connection, timeout: timeout, url: matcher) do
      {:ok, _} -> {:ok, true}
      {:error, _} -> {:ok, false}
    end
  end

  defp expect_url_with_text_matcher(frame_id, url_expectation, is_not?, ignore_case?, timeout, connection) do
    with {:ok, matches?} <-
           Frame.expect(frame_id,
             connection: connection,
             timeout: timeout,
             expression: "to.have.url",
             is_not: is_not?,
             expected_text: [serialize_expected_url(url_expectation, ignore_case?)]
           ) do
      {:ok, matches? != is_not?}
    end
  end

  defp serialize_expected_url(value, ignore_case?) when is_binary(value) do
    %{
      string: maybe_downcase_string(value, ignore_case?),
      ignore_case: ignore_case?
    }
  end

  defp serialize_expected_url(%Regex{source: source, opts: opts}, ignore_case?) do
    regex_flags =
      opts
      |> Serialization.regex_flags_for_protocol()
      |> maybe_add_regex_ignore_case(ignore_case?)

    %{
      regex_source: source,
      regex_flags: regex_flags,
      ignore_case: ignore_case?
    }
  end

  defp maybe_downcase_uri(uri, false), do: uri

  defp maybe_downcase_uri(uri, true) do
    uri |> URI.to_string() |> String.downcase() |> URI.parse()
  end

  defp maybe_downcase_string(value, false), do: value
  defp maybe_downcase_string(value, true), do: String.downcase(value)

  defp maybe_add_regex_ignore_case(opts, false), do: opts

  defp maybe_add_regex_ignore_case(opts, true) do
    if String.contains?(opts, "i"), do: opts, else: opts <> "i"
  end
end
