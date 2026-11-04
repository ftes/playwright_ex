# upstream: packages/playwright-core/src/client/frame.ts
defmodule PlaywrightJS.Client.Frame do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{BrowserContext, ElementHandle, Errors, JSHandle, Locator, Network, Page, Waiter}
  alias PlaywrightJS.Isomorphic.{LocatorUtils, UrlMatch}

  @k_lifecycle_events ["load", "domcontentloaded", "networkidle", "commit"]

  # upstream: frame.ts:67
  def from(frame) do
    frame
  end

  # upstream: frame.ts:71
  def from_nullable(frame) do
    if frame, do: from(frame), else: nil
  end

  # upstream: frame.ts:75
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    put(this, :_childFrames, [])
    put(this, :_detached, false)
    put(this, :_eventEmitter, EventEmitter.new(this.conn))
    # this._eventEmitter.setMaxListeners(0);  -- n/a
    # this.webmcp = new WebMCP(this);  -- not ported
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

      if !get(this, :_parentFrame) and event[:add] == "load" and get(this, :_page) do
        Page.emit(get(this, :_page), Events.Page.load(), get(this, :_page))
        BrowserContext.emit(Page.context(get(this, :_page)), Events.BrowserContext.page_load(), get(this, :_page))
      end

      if !get(this, :_parentFrame) and event[:add] == "domcontentloaded" and get(this, :_page),
        do: Page.emit(get(this, :_page), Events.Page.dom_content_loaded(), get(this, :_page))
    end)

    EventEmitter.on(_channel(this), "navigated", fn event ->
      put(this, :_url, event.url)
      put(this, :_name, event.name)
      # Main frame navigation destroys all execution contexts in the page,
      # erase the bindings backing the functions passed to evaluate().
      # if (!this._parentFrame && event.newDocument && this._page) this._page._eraseEvaluateCallbacks();  -- not ported
      EventEmitter.emit(get(this, :_eventEmitter), "navigated", event)

      if !event[:error] and get(this, :_page) do
        Page.emit(get(this, :_page), Events.Page.frame_navigated(), this)
        BrowserContext.emit(Page.context(get(this, :_page)), Events.BrowserContext.frame_navigated(), this)
      end
    end)

    this
  end

  # upstream: frame.ts:115
  def page(this) do
    get(this, :_page)
  end

  # upstream: frame.ts:119
  def _timeout(this, options \\ nil) do
    timeout_settings = (get(this, :_page) && get(get(this, :_page), :_timeoutSettings)) || TimeoutSettings.new(nil)
    TimeoutSettings.timeout(timeout_settings, options || %{})
  end

  # upstream: frame.ts:124
  def _navigation_timeout(this, options \\ nil) do
    timeout_settings = (get(this, :_page) && get(get(this, :_page), :_timeoutSettings)) || TimeoutSettings.new(nil)
    TimeoutSettings.navigation_timeout(timeout_settings, options || %{})
  end

  # upstream: frame.ts:129
  def goto(this, url, options \\ %{}) do
    wait_until = verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options[:waitUntil]))

    Network.Response.from_nullable(
      channel_call(this, :goto, Map.merge(%{url: url}, options) |> Map.put(:waitUntil, wait_until), _navigation_timeout(this, options))[
        :response
      ]
    )
  end

  # upstream: frame.ts:134
  defp _setup_navigation_waiter(this, options) do
    waiter = Waiter.new(get(this, :_page), "")
    if Page.is_closed(get(this, :_page)), do: Waiter.reject_immediately(waiter, Page._close_error_with_reason(get(this, :_page)))
    Waiter.reject_on_event(waiter, get(this, :_page), Events.Page.close(), fn -> Page._close_error_with_reason(get(this, :_page)) end)

    Waiter.reject_on_event(
      waiter,
      get(this, :_page),
      Events.Page.crash(),
      RuntimeError.exception("Navigation failed because page crashed!")
    )

    Waiter.reject_on_event(
      waiter,
      get(this, :_page),
      Events.Page.frame_detached(),
      RuntimeError.exception("Navigating frame was detached!"),
      fn frame -> frame == this end
    )

    timeout_options = TimeoutSettings.navigation_timeout(get(get(this, :_page), :_timeoutSettings), options)
    Waiter.reject_on_timeout(waiter, timeout_options, "Timeout #{timeout_options.timeout}ms exceeded.")
    waiter
  end

  # upstream: frame.ts:146
  def wait_for_navigation(this, options \\ %{}) do
    Page._wrap_api_call(
      get(this, :_page),
      fn _ ->
        wait_until = verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options[:waitUntil]))
        waiter = _setup_navigation_waiter(this, options)

        to_url = if is_binary(options[:url]), do: " to \"#{options.url}\"", else: ""
        Waiter.log(waiter, "waiting for navigation#{to_url} until \"#{wait_until}\"")

        navigated_event =
          Waiter.wait_for_event(waiter, get(this, :_eventEmitter), "navigated", fn event ->
            # Any failed navigation results in a rejection.
            if event[:error] do
              true
            else
              Waiter.log(waiter, "  navigated to \"#{event.url}\"")
              UrlMatch.url_matches(get(Page.context(get(this, :_page)), :_options)[:baseURL], event.url, options[:url])
            end
          end)

        if navigated_event[:error] do
          e = RuntimeError.exception(navigated_event.error)
          Waiter.wait_for_promise(waiter, Promise.rejected(this.conn, e))
        end

        if !set_has(this, :_loadStates, wait_until) do
          Waiter.wait_for_event(waiter, get(this, :_eventEmitter), "loadstate", fn s ->
            Waiter.log(waiter, "  \"#{s}\" event fired")
            s == wait_until
          end)
        end

        request = if navigated_event[:newDocument], do: Network.Request.from_nullable(navigated_event.newDocument[:request]), else: nil

        response =
          if request,
            do:
              Waiter.wait_for_promise(
                waiter,
                Promise.async(this.conn, fn -> Network.Request._internal_response(Network.Request._final_request(request)) end)
              ),
            else: nil

        Waiter.dispose(waiter)
        response
      end,
      %{title: "Wait for navigation"}
    )
  end

  # upstream: frame.ts:181
  def wait_for_load_state(this, state \\ "load", options \\ nil) do
    state = verify_load_state("state", state || "load")

    Page._wrap_api_call(
      get(this, :_page),
      fn _ ->
        waiter = _setup_navigation_waiter(this, options || %{})

        try do
          if set_has(this, :_loadStates, state) do
            Waiter.log(waiter, "  not waiting, \"#{state}\" event already fired")
            Waiter.throw_if_immediately_rejected(waiter)
          else
            Waiter.wait_for_event(waiter, get(this, :_eventEmitter), "loadstate", fn s ->
              Waiter.log(waiter, "  \"#{s}\" event fired")
              s == state
            end)
          end
        after
          Waiter.dispose(waiter)
        end

        nil
      end,
      %{title: "Wait for load state \"#{state}\""}
    )
  end

  # upstream: frame.ts:201
  def wait_for_url(this, url, options \\ nil) do
    wait_options = options || %{}

    if UrlMatch.url_matches(get(Page.context(get(this, :_page)), :_options)[:baseURL], url(this), url) do
      wait_for_load_state(this, wait_options[:waitUntil], wait_options)
    else
      wait_for_navigation(this, Map.merge(%{url: url}, wait_options))
      nil
    end
  end

  # upstream: frame.ts:289
  def url(this) do
    get(this, :_url)
  end

  # upstream: frame.ts:323
  def click(this, selector, options \\ %{}) do
    channel_call(this, :click, Map.merge(%{selector: selector}, options), _timeout(this, options))
  end

  # upstream: frame.ts:356
  def fill(this, selector, value, options \\ %{}) do
    channel_call(this, :fill, Map.merge(%{selector: selector, value: value}, options), _timeout(this, options))
  end

  # upstream: frame.ts:368
  def locator(this, selector, options \\ nil) do
    Locator.new(this, selector, options)
  end

  # upstream: frame.ts:372
  def get_by_test_id(this, test_id) do
    locator(this, LocatorUtils.get_by_test_id_selector(Locator.test_id_attribute_name(), test_id))
  end

  # upstream: frame.ts:380
  def get_by_label(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_label_selector(text, options))
  end

  # upstream: frame.ts:396
  def get_by_role(this, role, options \\ %{}) do
    locator(this, LocatorUtils.get_by_role_selector(role, options))
  end

  # upstream: frame.ts:458
  def select_option(this, selector, values, options \\ %{}) do
    channel_call(
      this,
      :selectOption,
      %{selector: selector} |> Map.merge(ElementHandle.convert_select_option_values(values)) |> Map.merge(options),
      _timeout(this, options)
    ).values
  end

  # upstream: frame.ts:462
  def set_input_files(this, selector, files, options \\ %{}) do
    converted = ElementHandle.convert_input_files(files, Page.context(page(this)))
    channel_call(this, :setInputFiles, %{selector: selector} |> Map.merge(converted) |> Map.merge(options), _timeout(this, options))
    nil
  end

  # upstream: frame.ts:475
  def check(this, selector, options \\ %{}) do
    channel_call(this, :check, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  # upstream: frame.ts:507
  def title(this) do
    channel_call(this, :title, %{}, TimeoutSettings.k_no_timeout()).value
  end

  # upstream: frame.ts:511
  def _expect(this, expression, options) do
    {%{timeout: timeout, signal: signal, title: title}, rest} =
      Map.split(Map.merge(%{signal: nil, title: nil}, options), [:timeout, :signal, :title])

    _wrap_api_call(
      this,
      fn _ ->
        params = Map.merge(%{expression: expression}, rest) |> Map.put(:isNot, !!rest[:isNot])
        params = Map.put(params, :expectedValue, JSHandle.serialize_argument(rest[:expectedValue]))

        try do
          channel_call(this, :expect, params, %{signal: signal, timeout: timeout})
          %{matches: !params.isNot}
        rescue
          e ->
            # if (e instanceof AbortError) return { matches: !!params.isNot, errorMessage: ... }  -- not ported: AbortSignal
            if !Errors.is_playwright_error(e), do: reraise(e, __STACKTRACE__)
            details = Map.get(e, :details)

            received =
              if details[:received],
                do: %{
                  value: if(details[:received][:value] != nil, do: JSHandle.parse_result(details[:received][:value])),
                  ariaSnapshot: details[:received][:ariaSnapshot]
                }

            %{
              matches: !!params.isNot,
              received: received,
              log: Map.get(e, :log),
              timedOut: details[:timedOut],
              errorMessage: if(details[:customErrorMessage], do: "Error: " <> details[:customErrorMessage])
            }
        end
      end,
      %{title: title}
    )
  end

  # upstream: frame.ts:544
  def verify_load_state(name, wait_until) do
    wait_until = if wait_until == "networkidle0", do: "networkidle", else: wait_until
    if wait_until not in @k_lifecycle_events, do: raise("#{name}: expected one of (load|domcontentloaded|networkidle|commit)")
    wait_until
  end
end
