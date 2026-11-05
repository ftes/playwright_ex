defmodule PlaywrightEx.Client.Frame do
  @upstream "packages/playwright-core/src/client/frame.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.Frame

  alias PlaywrightEx.AbortError
  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.ElementHandle
  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.FrameLocator
  alias PlaywrightEx.Client.JSHandle
  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Response
  alias PlaywrightEx.Client.Waiter
  alias PlaywrightEx.Client.WebMCP
  alias PlaywrightEx.Isomorphic.AbortSignal
  alias PlaywrightEx.Isomorphic.LocatorUtils
  alias PlaywrightEx.Isomorphic.UrlMatch

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
    put(this, :_eventEmitter, EventEmitter.new(this))
    # this._eventEmitter.setMaxListeners(0);  -- not ported: no listener leak warning in EventEmitter
    put(this, :webmcp, WebMCP.new(this))
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
      if !get(this, :_parentFrame) && event[:newDocument] && page, do: Page._erase_evaluate_callbacks(page)
      EventEmitter.emit(get(this, :_eventEmitter), "navigated", event)

      if !event[:error] and page do
        emit(page, Events.Page.frame_navigated(), this)
        emit(Page.context(page), Events.BrowserContext.frame_navigated(), this)
      end
    end)

    this
  end

  # readonly properties
  def webmcp(this), do: get(this, :webmcp)

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

  def wait_for_navigation(this, options \\ %{}) do
    options = options || %{}
    page = get(this, :_page)

    ChannelOwner._wrap_api_call(
      page,
      fn _ ->
        wait_until =
          verify_load_state("waitUntil", if(options[:waitUntil] == nil, do: "load", else: options.waitUntil))

        waiter = _setup_navigation_waiter(this, options)

        to_url = if is_binary(options[:url]), do: ~s( to "#{options.url}"), else: ""
        Waiter.log(waiter, ~s(waiting for navigation#{to_url} until "#{wait_until}"))

        navigated_event =
          Waiter.wait_for_event(waiter, get(this, :_eventEmitter), "navigated", fn event ->
            # Any failed navigation results in a rejection.
            if event[:error] do
              true
            else
              Waiter.log(waiter, ~s(  navigated to "#{event.url}"))

              # The LocalUtils comes first: globs become regexes through the driver (UrlMatch).
              UrlMatch.url_matches(
                Connection.local_utils(get(this, :_connection)),
                page && get(Page.context(page), :_options)[:baseURL],
                event.url,
                options[:url]
              )
            end
          end)

        if navigated_event[:error] do
          e = %RuntimeError{message: navigated_event.error}
          # e.stack = '';  -- n/a: Elixir exceptions carry no stack
          Waiter.wait_for_promise(waiter, Promise.rejected(e))
        end

        if !set_has(this, :_loadStates, wait_until) do
          Waiter.wait_for_event(waiter, get(this, :_eventEmitter), "loadstate", fn s ->
            Waiter.log(waiter, ~s(  "#{s}" event fired))
            s == wait_until
          end)
        end

        request = if navigated_event[:newDocument], do: Request.from_nullable(navigated_event.newDocument[:request])

        response =
          if request,
            do:
              Waiter.wait_for_promise(
                waiter,
                Promise.async(fn -> Request._internal_response(Request._final_request(request)) end)
              )

        Waiter.dispose(waiter)
        response
      end,
      %{title: "Wait for navigation"}
    )
  end

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

  def wait_for_url(this, url, options \\ nil) do
    wait_options = options || %{}
    page = get(this, :_page)

    # The LocalUtils comes first: globs become regexes through the driver (UrlMatch).
    if UrlMatch.url_matches(
         Connection.local_utils(get(this, :_connection)),
         page && get(Page.context(page), :_options)[:baseURL],
         url(this),
         url
       ) do
      wait_for_load_state(this, wait_options[:waitUntil], wait_options)
    else
      wait_for_navigation(this, Map.merge(%{url: url}, wait_options))
    end

    nil
  end

  def frame_element(this) do
    ElementHandle.from(channel_call(this, :frameElement, %{}, TimeoutSettings.k_no_timeout()).element)
  end

  def evaluate_handle(this, page_function, arg \\ nil, options \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    JSHandle.assert_evaluate_options(options)

    serialized_arg =
      if options[:exposeFunctions],
        do: JSHandle.serialize_argument_with_callbacks(this, get(this, :_page), arg),
        else: JSHandle.serialize_argument(arg)

    # isFunction: typeof pageFunction === 'function'  -- not ported: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evaluateExpressionHandle,
        %{expression: page_function, arg: serialized_arg},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.from(result.handle)
  end

  def evaluate(this, page_function, arg \\ nil, options \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    JSHandle.assert_evaluate_options(options)

    serialized_arg =
      if options[:exposeFunctions],
        do: JSHandle.serialize_argument_with_callbacks(this, get(this, :_page), arg),
        else: JSHandle.serialize_argument(arg)

    # isFunction: typeof pageFunction === 'function'  -- not ported: page functions are JS source (PLAN)
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
    # assertMaxArguments(arguments.length, 2);  -- not ported: Elixir arities are fixed
    # isFunction: typeof pageFunction === 'function'  -- not ported: page functions are JS source (PLAN)
    result =
      channel_call(
        this,
        :evaluateExpression,
        %{expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  # $  -- ported as query_selector/3
  def query_selector(this, selector, options \\ nil) do
    result =
      channel_call(
        this,
        :querySelector,
        Map.merge(%{selector: selector}, options || %{}),
        TimeoutSettings.k_no_timeout()
      )

    ElementHandle.from_nullable(result[:element])
  end

  def wait_for_selector(this, selector, options \\ %{}) do
    if options[:visibility], do: raise("options.visibility is not supported, did you mean options.state?")

    if options[:waitFor] && options[:waitFor] != "visible",
      do: raise("options.waitFor is not supported, did you mean options.state?")

    result = channel_call(this, :waitForSelector, Map.merge(%{selector: selector}, options), _timeout(this, options))
    ElementHandle.from_nullable(result[:element])
  end

  def dispatch_event(this, selector, type, event_init \\ nil, options \\ %{}) do
    channel_call(
      this,
      :dispatchEvent,
      Map.merge(%{selector: selector, type: type, eventInit: JSHandle.serialize_argument(event_init)}, options),
      _timeout(this, options)
    )

    nil
  end

  # $eval  -- ported as eval_on_selector/4
  def eval_on_selector(this, selector, page_function, arg \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    result =
      channel_call(
        this,
        :evalOnSelector,
        %{selector: selector, expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  # $$eval  -- ported as eval_on_selector_all/4
  def eval_on_selector_all(this, selector, page_function, arg \\ nil) do
    # assertMaxArguments(arguments.length, 3);  -- not ported: Elixir arities are fixed
    result =
      channel_call(
        this,
        :evalOnSelectorAll,
        %{selector: selector, expression: page_function, arg: JSHandle.serialize_argument(arg)},
        TimeoutSettings.k_no_timeout()
      )

    JSHandle.parse_result(result.value)
  end

  # $$  -- ported as query_selector_all/2
  def query_selector_all(this, selector) do
    result = channel_call(this, :querySelectorAll, %{selector: selector}, TimeoutSettings.k_no_timeout())
    Enum.map(result.elements, &ElementHandle.from/1)
  end

  def _query_count(this, selector) do
    channel_call(this, :queryCount, %{selector: selector}, TimeoutSettings.k_no_timeout()).value
  end

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

  def add_script_tag(this, options \\ %{}) do
    copy = options

    copy =
      if copy[:path] do
        copy = Map.put(copy, :content, File.read!(copy.path))
        Map.put(copy, :content, add_source_url_to_script(copy.content, copy.path))
      else
        copy
      end

    ElementHandle.from(channel_call(this, :addScriptTag, copy, TimeoutSettings.k_no_timeout()).element)
  end

  def add_style_tag(this, options \\ %{}) do
    copy = options

    copy =
      if copy[:path] do
        copy = Map.put(copy, :content, File.read!(copy.path))
        Map.put(copy, :content, copy.content <> "/*# sourceURL=" <> String.replace(copy.path, "\n", "") <> "*/")
      else
        copy
      end

    ElementHandle.from(channel_call(this, :addStyleTag, copy, TimeoutSettings.k_no_timeout()).element)
  end

  def click(this, selector, options \\ %{}) do
    channel_call(this, :click, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  def dblclick(this, selector, options \\ %{}) do
    channel_call(this, :dblclick, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  def drag_and_drop(this, source, target, options \\ %{}) do
    channel_call(this, :dragAndDrop, Map.merge(%{source: source, target: target}, options), _timeout(this, options))
    nil
  end

  def _drop(this, selector, payload, options \\ %{}) do
    file_params =
      if payload[:files] != nil do
        converted = ElementHandle.convert_input_files(payload.files, Page.context(page(this)))

        if converted[:localDirectory] || converted[:directoryStream],
          do: raise("Dropping a directory is not supported — pass individual files."),
          else: %{payloads: converted[:payloads], localPaths: converted[:localPaths], streams: converted[:streams]}
      else
        %{}
      end

    data_array =
      if payload[:data], do: Enum.map(payload.data, fn {mime_type, value} -> %{mimeType: mime_type, value: value} end)

    channel_call(
      this,
      :drop,
      Map.merge(Map.merge(Map.put(file_params, :selector, selector), %{data: data_array}), options),
      _timeout(this, options)
    )

    nil
  end

  def tap(this, selector, options \\ %{}) do
    channel_call(this, :tap, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  def fill(this, selector, value, options \\ %{}) do
    channel_call(this, :fill, Map.merge(%{selector: selector, value: value}, options), _timeout(this, options))
    nil
  end

  def _highlight(this, selector, style \\ nil) do
    channel_call(this, :highlight, %{selector: selector, style: style}, TimeoutSettings.k_no_timeout())
    nil
  end

  def _hide_highlight(this, selector) do
    channel_call(this, :hideHighlight, %{selector: selector}, TimeoutSettings.k_no_timeout())
    nil
  end

  def locator(this, selector, options \\ nil) do
    Locator.new(this, selector, options)
  end

  def get_by_test_id(this, test_id) do
    locator(this, LocatorUtils.get_by_test_id_selector(Locator.test_id_attribute_name(), test_id))
  end

  def get_by_alt_text(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_alt_text_selector(text, options))
  end

  def get_by_label(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_label_selector(text, options))
  end

  def get_by_placeholder(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_placeholder_selector(text, options))
  end

  def get_by_text(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_text_selector(text, options))
  end

  def get_by_title(this, text, options \\ nil) do
    locator(this, LocatorUtils.get_by_title_selector(text, options))
  end

  def get_by_role(this, role, options \\ %{}) do
    locator(this, LocatorUtils.get_by_role_selector(role, options || %{}))
  end

  def frame_locator(this, selector \\ nil) do
    FrameLocator.new(
      this,
      if(selector == nil, do: PlaywrightEx.Isomorphic.SelectorParser.k_any_frame_selector(), else: selector)
    )
  end

  def focus(this, selector, options \\ %{}) do
    channel_call(this, :focus, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  def text_content(this, selector, options \\ %{}) do
    # value === undefined ? null : value
    channel_call(this, :textContent, Map.merge(%{selector: selector}, options), _timeout(this, options))[:value]
  end

  def inner_text(this, selector, options \\ %{}) do
    channel_call(this, :innerText, Map.merge(%{selector: selector}, options), _timeout(this, options)).value
  end

  def inner_html(this, selector, options \\ %{}) do
    channel_call(this, :innerHTML, Map.merge(%{selector: selector}, options), _timeout(this, options)).value
  end

  def get_attribute(this, selector, name, options \\ %{}) do
    # value === undefined ? null : value
    channel_call(this, :getAttribute, Map.merge(%{selector: selector, name: name}, options), _timeout(this, options))[
      :value
    ]
  end

  def input_value(this, selector, options \\ %{}) do
    channel_call(this, :inputValue, Map.merge(%{selector: selector}, options), _timeout(this, options)).value
  end

  def is_checked(this, selector, options \\ %{}) do
    channel_call(this, :isChecked, Map.merge(%{selector: selector}, options), _timeout(this, options)).value
  end

  def is_disabled(this, selector, options \\ %{}) do
    channel_call(this, :isDisabled, Map.merge(%{selector: selector}, options), _timeout(this, options)).value
  end

  def is_editable(this, selector, options \\ %{}) do
    channel_call(this, :isEditable, Map.merge(%{selector: selector}, options), _timeout(this, options)).value
  end

  def is_enabled(this, selector, options \\ %{}) do
    channel_call(this, :isEnabled, Map.merge(%{selector: selector}, options), _timeout(this, options)).value
  end

  def is_hidden(this, selector, options \\ %{}) do
    channel_call(this, :isHidden, Map.merge(%{selector: selector}, options), TimeoutSettings.k_no_timeout()).value
  end

  def is_visible(this, selector, options \\ %{}) do
    channel_call(this, :isVisible, Map.merge(%{selector: selector}, options), TimeoutSettings.k_no_timeout()).value
  end

  def hover(this, selector, options \\ %{}) do
    channel_call(this, :hover, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  def select_option(this, selector, values, options \\ %{}) do
    channel_call(
      this,
      :selectOption,
      Map.merge(Map.merge(%{selector: selector}, ElementHandle.convert_select_option_values(values)), options),
      _timeout(this, options)
    ).values
  end

  def set_input_files(this, selector, files, options \\ %{}) do
    converted = ElementHandle.convert_input_files(files, Page.context(page(this)))

    channel_call(
      this,
      :setInputFiles,
      Map.merge(Map.merge(%{selector: selector}, converted), options),
      _timeout(this, options)
    )

    nil
  end

  def type(this, selector, text, options \\ %{}) do
    channel_call(this, :type, Map.merge(%{selector: selector, text: text}, options), _timeout(this, options))
    nil
  end

  def press(this, selector, key, options \\ %{}) do
    channel_call(this, :press, Map.merge(%{selector: selector, key: key}, options), _timeout(this, options))
    nil
  end

  def check(this, selector, options \\ %{}) do
    channel_call(this, :check, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  def uncheck(this, selector, options \\ %{}) do
    channel_call(this, :uncheck, Map.merge(%{selector: selector}, options), _timeout(this, options))
    nil
  end

  def set_checked(this, selector, checked, options \\ nil) do
    if checked,
      do: check(this, selector, options || %{}),
      else: uncheck(this, selector, options || %{})
  end

  def wait_for_timeout(this, timeout) do
    channel_call(this, :waitForTimeout, %{waitTimeout: timeout}, TimeoutSettings.k_no_timeout())
    nil
  end

  def wait_for_function(this, page_function, arg \\ nil, options \\ %{}) do
    options = options || %{}

    if is_binary(options[:polling]) and options.polling != "raf",
      do: raise("Unknown polling option: " <> options.polling)

    result =
      channel_call(
        this,
        :waitForFunction,
        Map.merge(options, %{
          pollingInterval: if(options[:polling] == "raf", do: nil, else: options[:polling]),
          expression: page_function,
          # isFunction: typeof pageFunction === 'function',  -- not ported: page functions are JS source (PLAN)
          arg: JSHandle.serialize_argument(arg)
        }),
        _timeout(this, options)
      )

    JSHandle.from(result[:handle])
  end

  def title(this) do
    channel_call(this, :title, %{}, TimeoutSettings.k_no_timeout()).value
  end

  def _expect(this, expression, options) do
    %{timeout: timeout} = options
    signal = options[:signal]
    title = options[:title]
    rest = Map.drop(options, [:timeout, :signal, :title])

    _wrap_api_call(
      this,
      fn _api_zone ->
        params = Map.merge(%{expression: expression}, Map.put(rest, :isNot, !!rest[:isNot]))
        params = Map.put(params, :expectedValue, JSHandle.serialize_argument(rest[:expectedValue]))

        try do
          channel_call(this, :expect, params, %{signal: signal, timeout: timeout})
          %{matches: !params.isNot}
        rescue
          e ->
            cond do
              is_struct(e, AbortError) ->
                %{
                  matches: !!params.isNot,
                  errorMessage: "Error: " <> AbortSignal.assertion_aborted_message(Map.get(e, :cause))
                }

              !Errors.is_playwright_error(e) ->
                reraise(e, __STACKTRACE__)

              true ->
                details = Map.get(e, :details) || %{}

                received =
                  if details[:received],
                    do: %{
                      value: if(details.received[:value] != nil, do: JSHandle.parse_result(details.received.value)),
                      ariaSnapshot: details.received[:ariaSnapshot]
                    }

                %{
                  matches: !!params.isNot,
                  received: received,
                  log: Map.get(e, :log),
                  timedOut: details[:timedOut],
                  errorMessage: if(details[:customErrorMessage], do: "Error: " <> details.customErrorMessage)
                }
            end
        end
      end,
      %{title: title}
    )
  end

  # clientHelper.ts addSourceUrlToScript
  defp add_source_url_to_script(source, path) do
    "#{source}\n//# sourceURL=#{String.replace(path, "\n", "")}"
  end

  def verify_load_state(name, wait_until) do
    wait_until = if wait_until == "networkidle0", do: "networkidle", else: wait_until

    if wait_until not in @k_lifecycle_events,
      do: raise("#{name}: expected one of (load|domcontentloaded|networkidle|commit)")

    wait_until
  end
end
