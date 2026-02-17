defmodule PlaywrightEx.Frame do
  @moduledoc """
  Interact with a Playwright `Frame` (usually the "main" frame of a browser page).

  There is no official documentation, since this is considered Playwright internal.

  References:
  - https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/frame.ts
  """

  alias PlaywrightEx.ChannelResponse
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Serialization

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      url: [
        type: :string,
        required: true,
        doc:
          "The destination URL, including scheme (e.g., `https://`) or a relative path (`base_url` was passed to `PlaywrightEx.Browser.new_context/2`)."
      ]
    )

  @doc """
  Navigates a frame to a specified URL and returns the main resource response. In cases of multiple redirects, it resolves with the final redirect's response.

  The method throws an error in these scenarios:
  - SSL errors occur (e.g., self-signed certificates)
  - The target URL is invalid
  - Navigation timeout is exceeded
  - Remote server is unresponsive or unreachable
  - Main resource fails to load

  However, it does **not** throw for valid HTTP status codes, including 404 or 500 responses—these can be retrieved via `response.status()`.

  Navigation to `about:blank` or same-URL hash changes return `null` rather than throwing. Headless mode cannot navigate to PDF documents.

  Reference: https://playwright.dev/docs/api/class-frame#frame-goto

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type goto_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec goto(PlaywrightEx.guid(), [goto_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def goto(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :goto, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Returns the frame's URL.

  Reference: https://playwright.dev/docs/api/class-frame#frame-url

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type url_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec url(PlaywrightEx.guid(), [url_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, String.t()} | {:error, any()}
  def url(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :url, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      expression: [
        type: :string,
        required: true,
        doc: "The JavaScript code to execute."
      ],
      is_function: [
        type: :boolean,
        default: false,
        doc: "Whether the expression is a function."
      ],
      arg: [
        type: :any,
        default: nil,
        doc: "Optional argument to pass to the function."
      ]
    )

  @doc """
  Executes JavaScript code within a frame's context and returns the result.

  Returns the return value of the expression. If the function passed to `evaluate/2` returns a Promise,
  then `evaluate/2` would wait for the promise to resolve and return its value.

  If the function passed to `evaluate/2` returns a non-Serializable value, then `evaluate/2` returns
  undefined. Playwright also supports transferring some additional values that are not serializable
  by JSON: -0, NaN, Infinity, -Infinity.

  Reference: https://playwright.dev/docs/api/class-frame#frame-evaluate

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type evaluate_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec evaluate(PlaywrightEx.guid(), [evaluate_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def evaluate(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    params =
      opts
      |> Map.new()
      |> Map.update!(:arg, &Serialization.serialize_arg/1)

    connection
    |> Connection.send(%{guid: frame_id, method: :evaluate_expression, params: params}, timeout)
    |> ChannelResponse.unwrap(&Serialization.deserialize_arg(&1.value))
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      key: [
        type: :string,
        required: true,
        doc: "Name of the key to press or a character to generate, such as `ArrowLeft` or `a`."
      ],
      delay: [
        type: :non_neg_integer,
        default: 0,
        doc: "Time in milliseconds to wait between `keydown` and `keyup`. Defaults to 0."
      ]
    )

  @doc """
  Focuses a matching element and activates a combination of keys.

  Reference: https://playwright.dev/docs/api/class-frame#frame-press

  This method waits for actionability checks, focuses the element, presses the specified key combination, and triggers keyboard events. If the element is detached during the action or exceeds the timeout, an error is thrown.

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type press_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec press(PlaywrightEx.guid(), [press_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def press(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :press, params: Map.new(opts)}, timeout + opts[:delay])
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      text: [
        type: :string,
        required: true,
        doc: "Text to type into the element."
      ],
      delay: [
        type: :non_neg_integer,
        default: 0,
        doc: "Time to wait between key presses in milliseconds. Defaults to 0."
      ]
    )

  @doc """
  Sends keydown, keypress/input, and keyup events for each character in the text.

  Reference: https://playwright.dev/docs/api/class-frame#frame-type

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @doc deprecated: "Use `fill/2` or `press/2` instead"
  @schema schema
  @type type_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec type(PlaywrightEx.guid(), [type_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def type(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(
      %{guid: frame_id, method: :type, params: Map.new(opts)},
      timeout + opts[:delay] * String.length(opts[:text])
    )
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Returns the page title.

  Reference: https://playwright.dev/docs/api/class-frame#frame-title

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type title_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec title(PlaywrightEx.guid(), [title_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t()} | {:error, any()}
  def title(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :title, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      is_not: [
        type: :boolean,
        default: false,
        doc: "Whether to negate the expectation."
      ],
      expression: [type: :string, required: true],
      selector: [type: :string],
      expected_text: [type: :any],
      expected_number: [type: :any],
      expression_arg: [type: :any]
    )

  @doc """
  Internal method for setting up expectations on the frame.

  This is an internal Playwright method used for implementing expectations and assertions on frame state.

  Reference: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/src/client/frame.ts

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type expect_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec expect(PlaywrightEx.guid(), [expect_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def expect(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :expect, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.matches)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [type: :string, required: true, doc: "A selector to search for an element."],
      state: [
        type: {:in, ["attached", "detached", "visible", "hidden"]},
        default: "visible",
        doc: ~s{State to wait for: "attached", "detached", "visible" (default), or "hidden".}
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Returns when element specified by selector satisfies state option. Returns `nil` if waiting for `hidden` or `detached`.

  This method waits for an element matching the selector to appear in the DOM, become visible, become hidden, or be detached, depending on the state option provided. If the selector already satisfies the condition at the time of calling, the method returns immediately. If the selector doesn't satisfy the condition within the timeout period, the function will throw an error.

  The method works across navigations and will continue waiting for the element even if the page navigates to a different URL.

  Reference: https://playwright.dev/docs/api/class-frame#frame-wait-for-selector

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type wait_for_selector_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec wait_for_selector(PlaywrightEx.guid(), [wait_for_selector_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def wait_for_selector(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :wait_for_selector, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(&Map.get(&1, :element))
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ]
    )

  @doc """
  Returns the element.innerHTML property from a matching element.

  This method returns the HTML content nested within the element, including all child elements and their markup.

  Reference: https://playwright.dev/docs/api/class-frame#frame-inner-html

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type inner_html_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec inner_html(PlaywrightEx.guid(), [inner_html_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t()} | {:error, any()}
  def inner_html(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :inner_html, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt()
    )

  @doc """
  Gets the full HTML contents of the frame, including the doctype.

  Reference: https://playwright.dev/docs/api/class-frame#frame-content

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type content_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec content(PlaywrightEx.guid(), [content_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t()} | {:error, any()}
  def content(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :content, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      value: [
        type: :string,
        required: true,
        doc: "Value to fill for the `<input>`, `<textarea>`, or `[contenteditable]` element."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Waits for an element matching selector, waits for actionability checks, focuses the element, fills it and triggers an `input` event after filling.

  You can pass an empty string to clear an input field. The method works with `<input>`, `<textarea>`, or `[contenteditable]` elements. If the target element is inside a `<label>` with an associated control, that control will be filled instead. The method throws an error if the element doesn't match the supported input types.

  For more granular keyboard control, the documentation recommends using `locator.pressSequentially()` as an alternative.

  Reference: https://playwright.dev/docs/api/class-frame#frame-fill

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type fill_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec fill(PlaywrightEx.guid(), [fill_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def fill(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :fill, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      options: [
        type: :any,
        required: true,
        doc: "Option to select. Can be a single value, label, index, or element reference, or an array of these."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Selects one or more options from a `<select>` element matching the provided selector.

  This method waits for an element matching the selector, waits for actionability checks,
  waits until all specified options are present in the `<select>` element and selects these options.
  It triggers `change` and `input` events once all the provided options have been selected.

  The method accepts options via value, label, index, or element reference and returns an array
  of the option values that were successfully selected. It throws an error if the target element
  is not a `<select>` element. However, if the element is inside a `<label>` element that has
  an associated control, the control will be used instead.

  Reference: https://playwright.dev/docs/api/class-frame#frame-select-option

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type select_option_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec select_option(PlaywrightEx.guid(), [select_option_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def select_option(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :select_option, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Checks a checkbox or radio input element.

  This method locates an element matching the given selector and performs a series of automated steps:
  finding the element, verifying it's a checkbox or radio input, performing actionability checks,
  scrolling into view if necessary, and using mouse interaction to click the center of the element.
  The method ensures the element becomes checked after the click.

  If the element is already checked, the method returns immediately without further action.
  Developers can bypass actionability checks using the `force` option. The method throws an error
  if the matched element is not a checkbox or radio input. A `TimeoutError` is thrown if operations
  don't complete within the specified timeout period. Zero timeout disables timeout restrictions.

  This method is discouraged in favor of using the locator-based `locator.check()` approach, which
  aligns with modern Playwright testing practices focusing on locators rather than direct selector-based actions.

  Reference: https://playwright.dev/docs/api/class-frame#frame-check

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type check_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec check(PlaywrightEx.guid(), [check_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def check(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :check, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Unchecks an element matching a selector by performing several steps: locating an element that matches the given selector, ensuring it's a checkbox or radio input, waiting for actionability checks (unless force is set), scrolling into view if needed, using the mouse to click the center of the element, and verifying the element is now unchecked. The method throws a TimeoutError if all steps don't complete within the specified timeout period.

  Reference: https://playwright.dev/docs/api/class-frame#frame-uncheck

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type uncheck_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec uncheck(PlaywrightEx.guid(), [uncheck_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def uncheck(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :uncheck, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      local_paths: [
        type: :any,
        required: true,
        doc:
          "File path(s) to set. Can be a string or a list of strings. Relative paths are resolved relative to the current working directory."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Sets the value of the file input to these file paths or files.

  This method expects selector to point to an input element. However, if the element is inside
  the `<label>` element that has an associated control, targets the control instead. If some of
  the file paths are relative paths, then they are resolved relative to the current working directory.
  For empty array, clears the selected files.

  Note: This method is discouraged. Use locator-based `locator.setInputFiles()` instead.

  Reference: https://playwright.dev/docs/api/class-frame#frame-set-input-files

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type set_input_files_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec set_input_files(PlaywrightEx.guid(), [set_input_files_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def set_input_files(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    params = opts |> Map.new() |> maybe_convert_to_payloads(connection)

    connection
    |> Connection.send(%{guid: frame_id, method: :set_input_files, params: params}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  defp maybe_convert_to_payloads(%{local_paths: local_paths} = params, connection) do
    if Connection.remote?(connection) do
      paths = local_paths |> List.wrap() |> Enum.map(&Path.expand/1)

      payloads =
        Enum.map(paths, fn path ->
          %{
            name: Path.basename(path),
            buffer: path |> File.read!() |> Base.encode64()
          }
        end)

      params |> Map.delete(:local_paths) |> Map.put(:payloads, payloads)
    else
      params
    end
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Clicks an element matching selector by performing the following steps:

  1. Locates an element matching the provided selector, waiting if necessary for it to appear in the DOM
  2. Performs actionability checks unless the force option is enabled; retries if the element detaches during checks
  3. Scrolls the element into view as needed
  4. Uses the mouse to click at the element's center or a specified position
  5. Waits for any initiated navigations to complete, unless noWaitAfter is set

  The method throws a TimeoutError if all steps don't complete within the specified timeout period. This deprecated method is discouraged in favor of using locator-based `locator.click()` instead.

  Reference: https://playwright.dev/docs/api/class-frame#frame-click

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type click_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec click(PlaywrightEx.guid(), [click_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def click(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :click, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Hovers over an element matching selector.

  This method is discouraged in favor of using locator-based `locator.hover()` instead.

  Reference: https://playwright.dev/docs/api/class-frame#frame-hover

  ## Example

      # Hover before manual drag (see https://playwright.dev/docs/input#dragging-manually)
      {:ok, _} = Frame.hover(frame_id, selector: "#item-to-be-dragged", timeout: 5000)

      # Get element position
      {:ok, box} = Frame.evaluate(frame_id,
        expression: "() => {
          const el = document.querySelector('#item-to-be-dragged');
          const box = el.getBoundingClientRect();
          return { x: box.x, y: box.y };
        }",
        is_function: true,
        timeout: 5000
      )

      # Drag 200px to the right
      {:ok, _} = Page.mouse_down(page_id, timeout: 5000)
      {:ok, _} = Page.mouse_move(page_id, x: box["x"] + 200, y: box["y"], timeout: 5000)
      {:ok, _} = Page.mouse_up(page_id, timeout: 5000)

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type hover_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec hover(PlaywrightEx.guid(), [hover_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def hover(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :hover, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ]
    )

  @doc """
  Calls the native [blur](https://developer.mozilla.org/en-US/docs/Web/API/HTMLElement/blur) function on the matching element, which removes focus from that element.

  Reference: https://playwright.dev/docs/api/class-frame#frame-blur

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type blur_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec blur(PlaywrightEx.guid(), [blur_opt() | PlaywrightEx.unknown_opt()]) :: {:ok, any()} | {:error, any()}
  def blur(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :blur, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      source: [
        type: :string,
        required: true,
        doc: "A selector to search for the source element to drag."
      ],
      target: [
        type: :string,
        required: true,
        doc: "A selector to search for the target element to drop onto."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Performs a drag-and-drop operation between two elements.

  This method takes a source selector (the element to drag) and a target selector (the element to drop onto),
  then simulates dragging from the source element to the target element.

  The method supports customization through optional parameters including:
  - **Position specification**: Define custom drag start and drop end points relative to element padding boxes
  - **Actionability control**: Bypass standard actionability checks if needed
  - **Strict mode**: Ensure selectors resolve to exactly one element
  - **Timeout configuration**: Set maximum operation duration
  - **Trial mode**: Perform actionability checks without executing the actual drag-and-drop action

  Reference: https://playwright.dev/docs/api/class-frame#frame-drag-and-drop

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type drag_and_drop_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec drag_and_drop(PlaywrightEx.guid(), [drag_and_drop_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def drag_and_drop(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :drag_and_drop, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Returns whether the element matching the selector is visible.

  Reference: https://playwright.dev/docs/api/class-frame#frame-is-visible

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type is_visible_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec is_visible(PlaywrightEx.guid(), [is_visible_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, boolean()} | {:error, any()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_visible(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :is_visible, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Returns whether the checkbox or radio element matching the selector is checked.

  Reference: https://playwright.dev/docs/api/class-frame#frame-is-checked

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type is_checked_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec is_checked(PlaywrightEx.guid(), [is_checked_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, boolean()} | {:error, any()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_checked(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :is_checked, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Returns whether the element matching the selector is disabled.

  Reference: https://playwright.dev/docs/api/class-frame#frame-is-disabled

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type is_disabled_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec is_disabled(PlaywrightEx.guid(), [is_disabled_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, boolean()} | {:error, any()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_disabled(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :is_disabled, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Returns whether the element matching the selector is enabled.

  Reference: https://playwright.dev/docs/api/class-frame#frame-is-enabled

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type is_enabled_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec is_enabled(PlaywrightEx.guid(), [is_enabled_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, boolean()} | {:error, any()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_enabled(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :is_enabled, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Returns whether the element matching the selector is editable.

  Reference: https://playwright.dev/docs/api/class-frame#frame-is-editable

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type is_editable_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec is_editable(PlaywrightEx.guid(), [is_editable_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, boolean()} | {:error, any()}
  # credo:disable-for-next-line Credo.Check.Readability.PredicateFunctionNames
  def is_editable(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :is_editable, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      name: [
        type: :string,
        required: true,
        doc: "Attribute name to get the value for."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Returns the element attribute value for the matching element.

  Reference: https://playwright.dev/docs/api/class-frame#frame-get-attribute

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type get_attribute_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec get_attribute(PlaywrightEx.guid(), [get_attribute_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t() | nil} | {:error, any()}
  def get_attribute(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :get_attribute, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(&Map.get(&1, :value))
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Returns the value for the matching `<input>`, `<textarea>`, or `<select>` element.

  Reference: https://playwright.dev/docs/api/class-frame#frame-input-value

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type input_value_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec input_value(PlaywrightEx.guid(), [input_value_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t()} | {:error, any()}
  def input_value(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :input_value, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Returns `element.textContent` for the matching element.

  Reference: https://playwright.dev/docs/api/class-frame#frame-text-content

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type text_content_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec text_content(PlaywrightEx.guid(), [text_content_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t() | nil} | {:error, any()}
  def text_content(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :text_content, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Returns `element.innerText` for the matching element.

  Reference: https://playwright.dev/docs/api/class-frame#frame-inner-text

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type inner_text_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec inner_text(PlaywrightEx.guid(), [inner_text_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, String.t()} | {:error, any()}
  def inner_text(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :inner_text, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1.value)
  end

  @doc """
  Focuses the matching element.

  Reference: https://playwright.dev/docs/api/class-frame#frame-focus

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type focus_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec focus(PlaywrightEx.guid(), [focus_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def focus(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    connection
    |> Connection.send(%{guid: frame_id, method: :focus, params: Map.new(opts)}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      selector: [
        type: :string,
        required: true,
        doc: "A selector to search for an element."
      ],
      type: [
        type: :string,
        required: true,
        doc: ~s(DOM event type: `"click"`, `"mousedown"`, etc.)
      ],
      event_init: [
        type: :any,
        default: nil,
        doc: "Optional event-specific initialization properties."
      ],
      strict: [
        type: :boolean,
        default: true,
        doc: "When true, the call requires selector to resolve to a single element."
      ]
    )

  @doc """
  Dispatches a DOM event on the matching element.

  The event is composed from the given `type` and optional `event_init` properties. Events are composed,
  not triggered, meaning event listeners are dispatched and any default actions can be prevented.

  Reference: https://playwright.dev/docs/api/class-frame#frame-dispatch-event

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type dispatch_event_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec dispatch_event(PlaywrightEx.guid(), [dispatch_event_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def dispatch_event(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    params =
      opts
      |> Map.new()
      |> Map.update(:event_init, Serialization.serialize_arg(nil), &Serialization.serialize_arg/1)

    connection
    |> Connection.send(%{guid: frame_id, method: :dispatch_event, params: params}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end

  schema =
    NimbleOptions.new!(
      connection: PlaywrightEx.Channel.connection_opt(),
      timeout: PlaywrightEx.Channel.timeout_opt(),
      expression: [
        type: :string,
        required: true,
        doc: "JavaScript expression to evaluate."
      ],
      is_function: [
        type: :boolean,
        default: false,
        doc: "Whether the expression is a function."
      ],
      arg: [
        type: :any,
        default: nil,
        doc: "Optional argument to pass to the function."
      ],
      polling: [
        type: {:or, [:pos_integer, :string]},
        default: "raf",
        doc: "Polling interval in ms, or `\"raf\"` for requestAnimationFrame."
      ]
    )

  @doc """
  Waits for the provided JavaScript expression to return a truthy value.

  Returns a JSHandle for the expression's return value once it becomes truthy. If the expression throws
  during evaluation, the method will keep retrying until it either succeeds or the timeout is reached.

  Reference: https://playwright.dev/docs/api/class-frame#frame-wait-for-function

  ## Options
  #{NimbleOptions.docs(schema)}
  """
  @schema schema
  @type wait_for_function_opt :: unquote(NimbleOptions.option_typespec(schema))
  @spec wait_for_function(PlaywrightEx.guid(), [wait_for_function_opt() | PlaywrightEx.unknown_opt()]) ::
          {:ok, any()} | {:error, any()}
  def wait_for_function(frame_id, opts \\ []) do
    {connection, opts} = opts |> PlaywrightEx.Channel.validate_known!(@schema) |> Keyword.pop!(:connection)
    {timeout, opts} = Keyword.pop!(opts, :timeout)

    params =
      opts
      |> Map.new()
      |> Map.update!(:arg, &Serialization.serialize_arg/1)

    connection
    |> Connection.send(%{guid: frame_id, method: :wait_for_function, params: params}, timeout)
    |> ChannelResponse.unwrap(& &1)
  end
end
