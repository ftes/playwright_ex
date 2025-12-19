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

  schema =
    NimbleOptions.new!(
      timeout: PlaywrightEx.Channel.timeout_opt(),
      x: [type: {:or, [:integer, :float]}, required: true, doc: "The x coordinate to move to."],
      y: [type: {:or, [:integer, :float]}, required: true, doc: "The y coordinate to move to."]
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
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: page_id, method: :mouseMove, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
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
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: page_id, method: :mouseDown, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
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
    {timeout, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:timeout)

    %{guid: page_id, method: :mouseUp, params: Map.new(opts)}
    |> Connection.send(timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
