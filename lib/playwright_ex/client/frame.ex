defmodule PlaywrightEx.Client.Frame do
  @upstream "packages/playwright-core/src/client/frame.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner

  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Client.Waiter

  # types.ts kLifecycleEvents
  @k_lifecycle_events ["load", "domcontentloaded", "networkidle", "commit"]

  def from(frame) do
    frame
  end

  def from_nullable(frame) do
    if frame, do: from(frame)
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_parentFrame, nil)
    put(this, :_url, "")
    put(this, :_name, "")
    put(this, :_detached, false)
    put(this, :_childFrames, [])
    put(this, :_eventEmitter, EventEmitter.new())
    # this._eventEmitter.setMaxListeners(0);  -- not ported: no leak warnings
    # this.webmcp = new WebMCP(this);  -- not ported: WebMCP
    put(this, :_parentFrame, from_nullable(initializer[:parentFrame]))
    if get(this, :_parentFrame), do: set_add(get(this, :_parentFrame), :_childFrames, this)
    put(this, :_name, initializer.name)
    put(this, :_url, initializer.url)
    put(this, :_loadStates, Enum.uniq(initializer.loadStates))

    EventEmitter.on(_channel(this), "loadstate", fn event ->
      if event[:add] do
        set_add(this, :_loadStates, event.add)
        EventEmitter.emit(get(this, :_eventEmitter), "loadstate", event.add)
      end

      if event[:remove], do: set_delete(this, :_loadStates, event.remove)
      page = get(this, :_page)

      if !get(this, :_parentFrame) and event[:add] == "load" and page do
        emit(page, Events.Page.load(), page)
        emit(Page.context(page), Events.BrowserContext.page_load(), page)
      end

      if !get(this, :_parentFrame) and event[:add] == "domcontentloaded" and page,
        do: emit(page, Events.Page.dom_content_loaded(), page)
    end)

    EventEmitter.on(_channel(this), "navigated", fn event ->
      put(this, :_url, event.url)
      put(this, :_name, event.name)
      page = get(this, :_page)
      # Main frame navigation destroys all execution contexts in the page,
      # erase the bindings backing the functions passed to evaluate().
      # if (!this._parentFrame && event.newDocument && this._page) this._page._eraseEvaluateCallbacks();  -- not ported: exposeFunctions
      EventEmitter.emit(get(this, :_eventEmitter), "navigated", event)

      if !event[:error] and page do
        emit(page, Events.Page.frame_navigated(), this)
        emit(Page.context(page), Events.BrowserContext.frame_navigated(), this)
      end
    end)

    this
  end

  def page(this) do
    get(this, :_page)
  end

  def _timeout(this, options \\ nil) do
    page = get(this, :_page)
    timeout_settings = (page && get(page, :_timeoutSettings)) || TimeoutSettings.new()
    TimeoutSettings.timeout(timeout_settings, options || %{})
  end

  def _navigation_timeout(this, options \\ nil) do
    page = get(this, :_page)
    timeout_settings = (page && get(page, :_timeoutSettings)) || TimeoutSettings.new()
    TimeoutSettings.navigation_timeout(timeout_settings, options || %{})
  end

  def goto(this, url, options \\ %{}) do
    wait_until = verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options.waitUntil))

    Response.from_nullable(
      channel_call(
        this,
        :goto,
        Map.put(Map.merge(%{url: url}, options), :waitUntil, wait_until),
        _navigation_timeout(this, options)
      )[:response]
    )
  end

  defp _setup_navigation_waiter(this, options) do
    page = get(this, :_page)
    waiter = Waiter.new(page, "")
    if Page.is_closed(page), do: Waiter.reject_immediately(waiter, Page._close_error_with_reason(page))
    Waiter.reject_on_event(waiter, page, Events.Page.close(), fn -> Page._close_error_with_reason(page) end)

    Waiter.reject_on_event(
      waiter,
      page,
      Events.Page.crash(),
      %RuntimeError{message: "Navigation failed because page crashed!"}
    )

    Waiter.reject_on_event(
      waiter,
      page,
      Events.Page.frame_detached(),
      %RuntimeError{message: "Navigating frame was detached!"},
      fn frame -> frame == this end
    )

    timeout_options = TimeoutSettings.navigation_timeout(get(page, :_timeoutSettings), options)
    Waiter.reject_on_timeout(waiter, timeout_options, "Timeout #{timeout_options.timeout}ms exceeded.")
    waiter
  end

  # waitForNavigation  -- not ported: urlMatch

  def wait_for_load_state(this, state \\ "load", options \\ nil) do
    state = verify_load_state("state", state || "load")
    page = get(this, :_page)

    ChannelOwner._wrap_api_call(
      page,
      fn _ ->
        waiter = _setup_navigation_waiter(this, options || %{})

        try do
          if set_has(this, :_loadStates, state) do
            Waiter.log(waiter, ~s(  not waiting, "#{state}" event already fired))
            Waiter.throw_if_immediately_rejected(waiter)
          else
            Waiter.wait_for_event(waiter, get(this, :_eventEmitter), "loadstate", fn s ->
              Waiter.log(waiter, ~s(  "#{s}" event fired))
              s == state
            end)
          end
        after
          Waiter.dispose(waiter)
        end

        nil
      end,
      %{title: ~s(Wait for load state "#{state}")}
    )
  end

  # waitForURL  -- not ported: urlMatch
  # frameElement, evaluateHandle  -- not ported: ElementHandle, JSHandle

  def evaluate(this, page_function, arg \\ nil, options \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    JSHandle.assert_evaluate_options(options)

    serialized_arg =
      if options[:exposeFunctions],
        # await serializeArgumentWithCallbacks(this, this._page, arg)  -- not ported: exposeFunctions
        do: raise("exposeFunctions is not supported yet"),
        else: JSHandle.serialize_argument(arg)

    # isFunction: typeof pageFunction === 'function'  -- omitted: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evaluateExpression,
        %{expression: page_function, arg: serialized_arg},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  def _evaluate_expose_utility_script(this, page_function, arg \\ nil) do
    result =
      channel_call(
        this,
        :evaluateExpression,
        %{expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  # $, waitForSelector, dispatchEvent, $eval, $$eval, $$, _queryCount  -- not ported: ElementHandle

  def content(this, options \\ %{}) do
    channel_call(this, :content, options, TimeoutSettings.k_no_timeout()).value
  end

  def set_content(this, html, options \\ %{}) do
    wait_until = verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options.waitUntil))

    channel_call(
      this,
      :setContent,
      Map.put(Map.merge(%{html: html}, options), :waitUntil, wait_until),
      _navigation_timeout(this, options)
    )

    nil
  end

  def name(this) do
    get(this, :_name) || ""
  end

  def url(this) do
    get(this, :_url)
  end

  def parent_frame(this) do
    get(this, :_parentFrame)
  end

  def child_frames(this) do
    get(this, :_childFrames)
  end

  def is_detached(this) do
    get(this, :_detached)
  end

  # addScriptTag, addStyleTag  -- not ported: ElementHandle
  # click, dblclick, dragAndDrop, _drop, tap, fill, _highlight, _hideHighlight  -- not ported: selectors
  # locator, getByTestId, getByAltText, getByLabel, getByPlaceholder, getByText, getByTitle, getByRole, frameLocator  -- not ported: Locator
  # focus, textContent, innerText, innerHTML, getAttribute, inputValue  -- not ported: selectors
  # isChecked, isDisabled, isEditable, isEnabled, isHidden, isVisible, hover  -- not ported: selectors
  # selectOption, setInputFiles, type, press, check, uncheck, setChecked  -- not ported: selectors

  def wait_for_timeout(this, timeout) do
    channel_call(this, :waitForTimeout, %{waitTimeout: timeout}, TimeoutSettings.k_no_timeout())
    nil
  end

  # waitForFunction  -- not ported: JSHandle

  def title(this) do
    channel_call(this, :title, %{}, TimeoutSettings.k_no_timeout()).value
  end

  # _expect  -- not ported: matchers

  def verify_load_state(name, wait_until) do
    wait_until = if wait_until == "networkidle0", do: "networkidle", else: wait_until

    if wait_until not in @k_lifecycle_events,
      do: raise("#{name}: expected one of (load|domcontentloaded|networkidle|commit)")

    wait_until
  end
end
