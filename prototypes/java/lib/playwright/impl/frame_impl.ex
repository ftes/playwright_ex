defmodule Playwright.Impl.FrameImpl do
  # upstream: FrameImpl.java:39
  use Playwright.Impl.ChannelOwner
  alias Playwright.{Frame, Locator}

  alias Playwright.Impl.{
    ListenerCollection,
    LocatorImpl,
    PageImpl,
    Serialization,
    ServerErrorWithDetails,
    TimeoutSettings,
    UrlMatcher,
    Utils,
    WaitableRace,
    WaitForEventLogger
  }

  alias Playwright.Impl.Protocol.{FrameExpectErrorDetails, FrameExpectResult}
  alias Playwright.PlaywrightException

  import Playwright.Impl.LocatorUtils,
    only: [get_by_label_selector: 2, get_by_role_selector: 2, get_by_test_id_selector: 2]

  # upstream: FrameImpl.java:52
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.init(__MODULE__, parent, type, guid, initializer)
    put(this, :child_frames, [])
    put(this, :load_states, MapSet.new())
    put(this, :internal_listeners, ListenerCollection.new())

    put(this, :name, initializer["name"])
    put(this, :url, initializer["url"])

    if Map.has_key?(initializer, "parentFrame") do
      put(this, :parent_frame, Connection.get_existing_object(this.connection, initializer["parentFrame"]["guid"]))
      update(get(this, :parent_frame), :child_frames, [], &(&1 ++ [this]))
    end

    for item <- initializer["loadStates"],
        do: update(this, :load_states, MapSet.new(), &MapSet.put(&1, load_state_from_protocol(item)))

    this
  end

  # upstream: FrameImpl.java:66
  defp load_state_from_protocol(value) do
    case value do
      "load" -> :load
      "domcontentloaded" -> :domcontentloaded
      "networkidle" -> :networkidle
      "commit" -> :commit
      _ -> raise PlaywrightException, message: "Unexpected value: " <> value
    end
  end

  # upstream: FrameImpl.java:108
  def select_option(this, selector, value, options) when is_binary(value) or is_nil(value) do
    values = if value == nil, do: nil, else: [value]
    select_option(this, selector, values, options)
  end

  # upstream: FrameImpl.java:120
  def select_option(this, selector, values, options) when is_list(values) do
    select_option_impl(this, selector, values, options)
  end

  # upstream: FrameImpl.java:217
  def check(this, selector, options) do
    options = options || %Frame.CheckOptions{}
    params = Serialization.to_json_tree(options)
    params = Map.put(params, "selector", selector)
    send_message(this, "check", params, timeout(this, options.timeout))
  end

  # upstream: FrameImpl.java:227
  def child_frames(this), do: get(this, :child_frames)

  # upstream: FrameImpl.java:232
  def click(this, selector, options), do: click_impl(this, selector, options, nil)

  # upstream: FrameImpl.java:236
  def click_impl(this, selector, options, steps) do
    options = options || %Frame.ClickOptions{}
    params = Serialization.to_json_tree(options)
    params = Map.put(params, "selector", selector)
    params = if steps != nil, do: Map.put(params, "steps", steps), else: params
    send_message(this, "click", params, timeout(this, options.timeout))
  end

  # upstream: FrameImpl.java:308
  def fill(this, selector, value, options) do
    options = options || %Frame.FillOptions{}
    params = Serialization.to_json_tree(options)
    params = Map.put(params, "selector", selector)
    params = Map.put(params, "value", value)
    send_message(this, "fill", params, timeout(this, options.timeout))
  end

  # upstream: FrameImpl.java:355
  def get_by_label(this, text, options) when is_binary(text) do
    locator(this, get_by_label_selector(text, Utils.convert_type(options, Locator.GetByLabelOptions)), nil)
  end

  # upstream: FrameImpl.java:360
  def get_by_label(this, %Regex{} = text, options) do
    locator(this, get_by_label_selector(text, Utils.convert_type(options, Locator.GetByLabelOptions)), nil)
  end

  # upstream: FrameImpl.java:375
  def get_by_role(this, role, options) do
    locator(this, get_by_role_selector(role, Utils.convert_type(options, Locator.GetByRoleOptions)), nil)
  end

  # upstream: FrameImpl.java:380
  def get_by_test_id(this, test_id) when is_binary(test_id) do
    locator(this, get_by_test_id_selector(test_id, get(this.connection, :playwright)), nil)
  end

  # upstream: FrameImpl.java:385
  def get_by_test_id(this, %Regex{} = test_id) do
    locator(this, get_by_test_id_selector(test_id, get(this.connection, :playwright)), nil)
  end

  # upstream: FrameImpl.java:424
  def navigate(this, url, options), do: navigate_impl(this, url, options)

  # upstream: FrameImpl.java:428
  def navigate_impl(this, url, options) do
    options = options || %Frame.NavigateOptions{}
    params = Serialization.to_json_tree(options)
    params = Map.put(params, "url", url)
    result = send_message(this, "goto", params, navigation_timeout(this, options.timeout))
    json_response = result["response"]

    if json_response == nil do
      nil
    else
      Connection.get_existing_object(this.connection, json_response["guid"])
    end
  end

  # upstream: FrameImpl.java:535
  def is_detached(this), do: get(this, :is_detached) == true

  # upstream: FrameImpl.java:605
  def locator(this, selector, options),
    do: LocatorImpl.new(this, selector, Utils.convert_type(options, Locator.LocatorOptions))

  # upstream: FrameImpl.java:620
  def name(this), do: get(this, :name)

  # upstream: FrameImpl.java:625
  def page(this), do: get(this, :page)

  # upstream: FrameImpl.java:630
  def parent_frame(this), do: get(this, :parent_frame)

  # upstream: FrameImpl.java:666
  def select_option_impl(this, selector, values, options) do
    options = options || %Frame.SelectOptionOptions{}
    params = Serialization.to_json_tree(options)
    params = Map.put(params, "selector", selector)

    params =
      if values != nil, do: Map.put(params, "options", Serialization.to_select_value_or_label(values)), else: params

    select_option(this, params, options.timeout)
  end

  # upstream: FrameImpl.java:695
  defp select_option(this, params, timeout) do
    json = send_message(this, "selectOption", params, timeout(this, timeout))
    Serialization.parse_string_list(json["values"])
  end

  # upstream: FrameImpl.java:724
  def set_input_files(this, selector, files, options) when is_binary(files) do
    set_input_files(this, selector, [files], options)
  end

  # upstream: FrameImpl.java:729
  def set_input_files(this, selector, files, options) when is_list(files) do
    set_input_files_impl(this, selector, files, options)
  end

  # upstream: FrameImpl.java:733
  def set_input_files_impl(this, selector, files, options) do
    options = options || %Frame.SetInputFilesOptions{}
    params = Serialization.to_json_tree(options)
    params = Utils.add_file_path_upload_params(files, params, PageImpl.context(get(this, :page)))
    params = Map.put(params, "selector", selector)
    send_message(this, "setInputFiles", params, timeout(this, options.timeout))
  end

  # upstream: FrameImpl.java:785
  def title(this) do
    json = send_message(this, "title")
    json["value"]
  end

  # upstream: FrameImpl.java:812
  def url(this), do: get(this, :url)

  # upstream: FrameImpl.java:830
  def wait_for_load_state(this, state, options) do
    with_wait_logging(this, "Frame.waitForLoadState", fn logger ->
      wait_for_load_state_impl(this, state, options, logger)
      nil
    end)
  end

  # upstream: FrameImpl.java:837 + :841 (the LoadState -> WaitUntilState overload collapses: both are atoms)
  def wait_for_load_state_impl(this, state, options, logger) do
    options = options || %Frame.WaitForLoadStateOptions{}
    state = if state == nil, do: :load, else: state

    waitables = []
    waitables = waitables ++ [__MODULE__.WaitForLoadStateHelper.new(this, state, logger)]
    waitables = waitables ++ [PageImpl.create_wait_for_close_helper(get(this, :page))]
    waitables = waitables ++ [PageImpl.create_waitable_timeout(get(this, :page), options.timeout)]
    run_until(this, fn -> nil end, WaitableRace.new(waitables))
  end

  defmodule WaitForLoadStateHelper do
    # upstream: FrameImpl.java:856  (private inner class implements Waitable<Void>, Consumer<WaitUntilState>)
    alias Playwright.Impl.{Heap, ListenerCollection, WaitForEventLogger}
    @behaviour Playwright.Impl.Waitable
    defstruct [:id, :outer, :expected_state, :logger]

    # upstream: FrameImpl.java:861
    def new(outer, state, logger) do
      this = %__MODULE__{id: make_ref(), outer: outer, expected_state: state, logger: logger}
      Heap.put(this, :is_done, MapSet.member?(Heap.get(outer, :load_states), state))

      if !Heap.get(this, :is_done),
        do: ListenerCollection.add(Heap.get(outer, :internal_listeners), :loadstate, consumer(this))

      this
    end

    defp consumer(this), do: fn state -> accept(this, state) end

    # upstream: FrameImpl.java:871
    def accept(this, state) do
      WaitForEventLogger.log(this.logger, "  load state changed to #{state}")

      if this.expected_state == state do
        Heap.put(this, :is_done, true)
        dispose(this)
      end
    end

    # upstream: FrameImpl.java:879
    @impl true
    def dispose(this),
      do: ListenerCollection.remove(Heap.get(this.outer, :internal_listeners), :loadstate, consumer(this))

    # upstream: FrameImpl.java:883
    @impl true
    def is_done(this), do: Heap.get(this, :is_done)

    # upstream: FrameImpl.java:888
    @impl true
    def get(_this), do: nil
  end

  defmodule WaitForNavigationHelper do
    # upstream: FrameImpl.java:893  (private inner class implements Waitable<Response>, Consumer<JsonObject>)
    alias Playwright.Impl.{Connection, FrameImpl, Heap, ListenerCollection, UrlMatcher, WaitForEventLogger}
    alias Playwright.PlaywrightException
    @behaviour Playwright.Impl.Waitable
    defstruct [:id, :outer, :matcher, :expected_load_state, :logger]

    # upstream: FrameImpl.java:902
    def new(outer, matcher, expected_load_state, logger) do
      this = %__MODULE__{
        id: make_ref(),
        outer: outer,
        matcher: matcher,
        expected_load_state: expected_load_state,
        logger: logger
      }

      ListenerCollection.add(Heap.get(outer, :internal_listeners), :navigated, consumer(this))
      this
    end

    defp consumer(this), do: fn params -> accept(this, params) end

    # upstream: FrameImpl.java:910
    def accept(this, params) do
      url = params["url"]
      WaitForEventLogger.log(this.logger, "  navigated to " <> url)

      if UrlMatcher.test(this.matcher, url) do
        if Map.has_key?(params, "error") do
          Heap.put(this, :exception, %PlaywrightException{message: params["error"]})
        else
          if Map.has_key?(params, "newDocument") do
            json_req = params["newDocument"]["request"]

            if json_req != nil,
              do: Heap.put(this, :request, Connection.get_existing_object(this.outer.connection, json_req["guid"]))
          end

          Heap.put(
            this,
            :load_state_helper,
            FrameImpl.WaitForLoadStateHelper.new(this.outer, this.expected_load_state, this.logger)
          )
        end

        ListenerCollection.remove(Heap.get(this.outer, :internal_listeners), :navigated, consumer(this))
      end
    end

    # upstream: FrameImpl.java:931
    @impl true
    def dispose(this) do
      ListenerCollection.remove(Heap.get(this.outer, :internal_listeners), :navigated, consumer(this))
      load_state_helper = Heap.get(this, :load_state_helper)
      if load_state_helper != nil, do: FrameImpl.WaitForLoadStateHelper.dispose(load_state_helper)
    end

    # upstream: FrameImpl.java:939
    @impl true
    def is_done(this) do
      cond do
        Heap.get(this, :exception) != nil ->
          true

        Heap.get(this, :load_state_helper) != nil ->
          FrameImpl.WaitForLoadStateHelper.is_done(Heap.get(this, :load_state_helper))

        true ->
          false
      end
    end

    # upstream: FrameImpl.java:950
    @impl true
    def get(this) do
      exception = Heap.get(this, :exception)
      if exception != nil, do: raise(exception)
      request = Heap.get(this, :request)
      # request.finalRequest().response(): RequestImpl not ported, return the request itself
      if request == nil, do: nil, else: request
    end
  end

  # upstream: FrameImpl.java:971
  defp wait_for_navigation_impl(this, logger, code, options, matcher) do
    options = options || %Frame.WaitForNavigationOptions{}
    options = if options.wait_until == nil, do: %{options | wait_until: :load}, else: options

    waitables = []
    page = get(this, :page)

    matcher =
      if matcher == nil,
        do:
          UrlMatcher.for_one_of(
            Playwright.Impl.BrowserContextImpl.base_url(PageImpl.context(page)),
            options.url,
            Connection.local_utils(this.connection),
            false
          ),
        else: matcher

    WaitForEventLogger.log(logger, "waiting for navigation #{matcher}")
    waitables = waitables ++ [WaitForNavigationHelper.new(this, matcher, options.wait_until, logger)]
    waitables = waitables ++ [PageImpl.create_wait_for_close_helper(page)]
    waitables = waitables ++ [PageImpl.create_waitable_frame_detach(page, this)]
    waitables = waitables ++ [PageImpl.create_waitable_navigation_timeout(page, options.timeout)]
    run_until(this, code, WaitableRace.new(waitables))
  end

  # upstream: FrameImpl.java:1040
  def wait_for_url_impl(this, logger, matcher, options) do
    WaitForEventLogger.log(logger, "waiting for url #{matcher}")
    options = options || %Frame.WaitForURLOptions{}

    if UrlMatcher.test(matcher, url(this)) do
      wait_for_load_state_impl(
        this,
        options.wait_until,
        Utils.convert_type(options, Frame.WaitForLoadStateOptions),
        logger
      )
    else
      wait_for_navigation_impl(
        this,
        logger,
        fn -> nil end,
        Utils.convert_type(options, Frame.WaitForNavigationOptions),
        matcher
      )
    end
  end

  # upstream: FrameImpl.java:1111
  @impl true
  def handle_event(this, event, params) do
    cond do
      "loadstate" == event ->
        add = params["add"]

        if add != nil do
          state = load_state_from_protocol(add)
          update(this, :load_states, MapSet.new(), &MapSet.put(&1, state))
          page = get(this, :page)

          if get(this, :parent_frame) == nil and page != nil do
            cond do
              state == :load ->
                ListenerCollection.notify(get(page, :listeners), :load, page)
                Playwright.Impl.BrowserContextImpl.notify_page_load(get(page, :browser_context), page)

              state == :domcontentloaded ->
                ListenerCollection.notify(get(page, :listeners), :domcontentloaded, page)

              true ->
                nil
            end
          end

          ListenerCollection.notify(get(this, :internal_listeners), :loadstate, state)
        end

        remove = params["remove"]

        if remove != nil,
          do: update(this, :load_states, MapSet.new(), &MapSet.delete(&1, load_state_from_protocol(remove)))

      "navigated" == event ->
        put(this, :url, params["url"])
        put(this, :name, params["name"])
        page = get(this, :page)
        if !Map.has_key?(params, "error") and page != nil, do: PageImpl.frame_navigated(page, this)
        ListenerCollection.notify(get(this, :internal_listeners), :navigated, params)

      true ->
        nil
    end
  end

  # upstream: FrameImpl.java:1146
  def timeout(this, timeout) do
    page = get(this, :page)

    if page != nil,
      do: TimeoutSettings.timeout(get(page, :timeout_settings), timeout),
      else: TimeoutSettings.timeout(TimeoutSettings.new(), timeout)
  end

  # upstream: FrameImpl.java:1153
  def navigation_timeout(this, timeout) do
    page = get(this, :page)

    if page != nil,
      do: TimeoutSettings.navigation_timeout(get(page, :timeout_settings), timeout),
      else: TimeoutSettings.navigation_timeout(TimeoutSettings.new(), timeout)
  end

  # upstream: FrameImpl.java:1160
  def expect(this, expression, options, title), do: with_title(this, title, fn -> expect(this, expression, options) end)

  # upstream: FrameImpl.java:1164
  def expect(this, expression, options) do
    params = Serialization.to_json_tree(options)
    params = Map.put(params, "expression", expression)
    result = %FrameExpectResult{}

    try do
      send_message(this, "expect", params, options.timeout)
      %{result | matches: !options.is_not}
    rescue
      e in ServerErrorWithDetails ->
        details = Serialization.from_json(ServerErrorWithDetails.error_details(e), FrameExpectErrorDetails)
        result = %{result | matches: options.is_not}
        result = %{result | received: details.received}

        result = %{
          result
          | error_message:
              if(details.custom_error_message == nil, do: nil, else: "Error: " <> details.custom_error_message)
        }

        %{result | log: ServerErrorWithDetails.log(e)}
    end
  end
end
