# upstream: playwright/_impl/_frame.py (subset)
defmodule Playwright.Impl.Frame do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.{Channel, ChannelOwner}

  alias Playwright.Impl.{
    BrowserContext,
    ElementHandle,
    EventContextManagerImpl,
    JSHandle,
    Locator,
    Page,
    SetInputFilesHelpers,
    Waiter
  }

  alias Playwright.Impl.Errors
  alias Playwright.Impl.Errors.Error
  alias Playwright.Impl.Helper.TimeoutSettings
  alias Pyee.EventEmitter
  import Playwright.Impl.Connection, only: [from_channel: 1, from_nullable_channel: 1]
  import Playwright.Impl.Helper, only: [locals_to_params: 1, monotonic_time: 0, url_matches: 3]

  # upstream: _frame.py:90
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)
    Py.set(self, :_parent_frame, from_nullable_channel(initializer["parentFrame"]))
    if self[:_parent_frame], do: Py.append(self[:_parent_frame], :_child_frames, self)
    Py.set(self, :_name, initializer["name"])
    Py.set(self, :_url, initializer["url"])
    Py.set(self, :_detached, false)
    Py.set(self, :_child_frames, [])
    Py.set(self, :_page, nil)
    Py.set(self, :_load_states, MapSet.new(initializer["loadStates"]))
    Py.set(self, :_event_emitter, EventEmitter.new())
    # self._webmcp = WebMCP(self) (omitted)
    Channel.on(self[:_channel], "loadstate", fn params ->
      _on_load_state(self, params["add"], params["remove"])
    end)

    Channel.on(self[:_channel], "navigated", fn params -> _on_frame_navigated(self, params) end)
    self
  end

  # upstream: _frame.py:117
  def _on_load_state(self, add \\ nil, remove \\ nil) do
    cond do
      add ->
        Py.set(self, :_load_states, MapSet.put(self[:_load_states], add))
        EventEmitter.emit(self[:_event_emitter], "loadstate", add)

      remove && remove in self[:_load_states] ->
        Py.set(self, :_load_states, MapSet.delete(self[:_load_states], remove))

      true ->
        nil
    end

    if !self[:_parent_frame] && add == "load" && self[:_page] do
      Page.emit(self[:_page], "load", self[:_page])
      BrowserContext.emit(Page.context(self[:_page]), "pageload", self[:_page])
    end

    if !self[:_parent_frame] && add == "domcontentloaded" && self[:_page],
      do: Page.emit(self[:_page], "domcontentloaded", self[:_page])
  end

  # upstream: _frame.py:131
  def _on_frame_navigated(self, event) do
    Py.set(self, :_url, event["url"])
    Py.set(self, :_name, event["name"])
    EventEmitter.emit(self[:_event_emitter], "navigated", event)

    if not Map.has_key?(event, "error") && self[:_page] do
      Page.emit(self[:_page], "framenavigated", self)
      BrowserContext.emit(Page.context(self[:_page]), "framenavigated", self)
    end
  end

  # upstream: _frame.py:139
  def _query_count(self, selector),
    do: Channel.send(self[:_channel], "queryCount", nil, %{"selector" => selector})

  # upstream: _frame.py:143
  def page(self) do
    true = self[:_page] != nil
    self[:_page]
  end

  # upstream: _frame.py:147
  def goto(self, url, opts \\ []) do
    from_nullable_channel(
      Channel.send(
        self[:_channel],
        "goto",
        &_navigation_timeout(self, &1),
        locals_to_params(binding())
      )
    )
  end

  # upstream: _frame.py:163
  def _setup_navigation_waiter(self, wait_name, timeout \\ nil) do
    true = self[:_page] != nil
    waiter = Waiter.init(self[:_page], "frame.#{wait_name}")

    Waiter.reject_on_event(waiter, self[:_page], "close", fn ->
      Page._close_error_with_reason(self[:_page])
    end)

    Waiter.reject_on_event(
      waiter,
      self[:_page],
      "crash",
      Error.new("Navigation failed because page crashed!")
    )

    Waiter.reject_on_event(
      waiter,
      self[:_page],
      "framedetached",
      Error.new("Navigating frame was detached!"),
      fn frame -> frame == self end
    )

    timeout = TimeoutSettings.navigation_timeout(self[:_page][:_timeout_settings], timeout)
    Waiter.reject_on_timeout(waiter, timeout, "Timeout #{timeout}ms exceeded.")
    waiter
  end

  # upstream: _frame.py:184
  def _expect(self, selector, expression, options, title \\ nil) do
    options =
      if Map.has_key?(options, "expectedValue"),
        do:
          Map.put(options, "expectedValue", JSHandle.serialize_argument(options["expectedValue"])),
        else: options

    try do
      Channel.send(
        self[:_channel],
        "expect",
        &_timeout(self, &1),
        Map.merge(%{"selector" => selector, "expression" => expression}, options),
        false,
        title
      )

      %{"matches" => !options["isNot"]}
    rescue
      e in [Error, Errors.TimeoutError, Errors.TargetClosedError] ->
        if !e._details, do: reraise(e, __STACKTRACE__)
        details = e._details
        received = details["received"]

        received =
          if received do
            %{
              "value" =>
                if(Map.has_key?(received, "value"),
                  do: JSHandle.parse_value(received["value"]),
                  else: nil
                ),
              "ariaSnapshot" => received["ariaSnapshot"]
            }
          end

        %{
          "matches" => !!options["isNot"],
          "received" => received,
          "timedOut" => details["timedOut"],
          "errorMessage" =>
            if(details["customErrorMessage"],
              do: "Error: " <> details["customErrorMessage"],
              else: nil
            ),
          "log" => e._log
        }
    end
  end

  # upstream: _frame.py:229
  def expect_navigation(self, url \\ nil, waitUntil \\ nil, timeout \\ nil) do
    true = self[:_page] != nil
    waitUntil = if !waitUntil, do: "load", else: waitUntil

    timeout =
      if timeout == nil,
        do: TimeoutSettings.navigation_timeout(self[:_page][:_timeout_settings]),
        else: timeout

    deadline = monotonic_time() + timeout
    waiter = _setup_navigation_waiter(self, "expect_navigation", timeout)

    to_url = if url, do: ~s( to "#{inspect(url)}"), else: ""
    Waiter.log(waiter, "waiting for navigation#{to_url} until '#{waitUntil}'")

    predicate = fn event ->
      # Any failed navigation results in a rejection.
      if event["error"] do
        true
      else
        Waiter.log(waiter, ~s(  navigated to "#{event["url"]}"))
        url_matches(self[:_page][:_browser_context][:_base_url], event["url"], url)
      end
    end

    Waiter.wait_for_event(waiter, self[:_event_emitter], "navigated", predicate)

    continuation = fn ->
      event = Asyncio.Future.await(Waiter.result(waiter))
      if Map.has_key?(event, "error"), do: raise(Error.new(event["error"]))

      if waitUntil not in self[:_load_states] do
        t = deadline - monotonic_time()
        if t > 0, do: _wait_for_load_state_impl(self, waitUntil, t)
      end

      if Map.has_key?(event, "newDocument") &&
           Map.has_key?(event["newDocument"] || %{}, "request") do
        _request = from_channel(event["newDocument"]["request"])
        # return await request.response()  (Request/Response not in prototype subset)
        nil
      else
        nil
      end
    end

    EventContextManagerImpl.init(Asyncio.create_task(continuation))
  end

  # upstream: _frame.py:279
  def wait_for_url(self, url, opts \\ []) do
    true = self[:_page] != nil

    if url_matches(self[:_page][:_browser_context][:_base_url], url(self), url) do
      _wait_for_load_state_impl(self, opts[:waitUntil], opts[:timeout])
    else
      cm = expect_navigation(self, url, opts[:waitUntil], opts[:timeout])
      EventContextManagerImpl.aenter(cm)
      EventContextManagerImpl.aexit(cm)
    end

    nil
  end

  # upstream: _frame.py:294
  def wait_for_load_state(self, state \\ nil, opts \\ []),
    do: _wait_for_load_state_impl(self, state, opts[:timeout])

  # upstream: _frame.py:301
  def _wait_for_load_state_impl(self, state \\ nil, timeout \\ nil) do
    state = if !state, do: "load", else: state

    if state not in ["load", "domcontentloaded", "networkidle", "commit"],
      do: raise(Error.new("state: expected one of (load|domcontentloaded|networkidle|commit)"))

    waiter = _setup_navigation_waiter(self, "wait_for_load_state", timeout)

    if state in self[:_load_states] do
      Waiter.log(waiter, ~s(  not waiting, "#{state}" event already fired))
      # TODO: align with upstream
      Waiter._fulfill(waiter, nil)
    else
      handle_load_state_event = fn actual_state ->
        Waiter.log(waiter, ~s("#{actual_state}" event fired))
        actual_state == state
      end

      Waiter.wait_for_event(waiter, self[:_event_emitter], "loadstate", handle_load_state_event)
    end

    Asyncio.Future.await(Waiter.result(waiter))
  end

  # upstream: _frame.py:329
  def _timeout(self, timeout) do
    timeout_settings =
      if self[:_page], do: self[:_page][:_timeout_settings], else: TimeoutSettings.init(nil)

    TimeoutSettings.timeout(timeout_settings, timeout)
  end

  # upstream: _frame.py:335
  def _navigation_timeout(self, timeout) do
    timeout_settings =
      if self[:_page], do: self[:_page][:_timeout_settings], else: TimeoutSettings.init(nil)

    TimeoutSettings.navigation_timeout(timeout_settings, timeout)
  end

  # upstream: _frame.py:514
  def name(self), do: self[:_name] || ""

  # upstream: _frame.py:518
  def url(self), do: self[:_url] || ""

  # upstream: _frame.py:526
  def parent_frame(self), do: self[:_parent_frame]

  # upstream: _frame.py:530
  def child_frames(self), do: self[:_child_frames]

  # upstream: _frame.py:533
  def is_detached(self), do: self[:_detached]

  # upstream: _frame.py:565
  def click(self, selector, opts \\ []), do: _click(self, selector, locals_to_params(opts))

  # upstream: _frame.py:582
  def _click(self, selector, opts \\ []) do
    Channel.send(self[:_channel], "click", &_timeout(self, &1), locals_to_params(binding()))
  end

  # upstream: _frame.py:632
  def fill(self, selector, value, opts \\ []),
    do: _fill(self, selector, value, locals_to_params(opts))

  # upstream: _frame.py:643
  def _fill(self, selector, value, opts \\ []) do
    Channel.send(self[:_channel], "fill", &_timeout(self, &1), locals_to_params(binding()))
  end

  # upstream: _frame.py:655
  def locator(self, selector, opts \\ []) do
    Locator.init(self, selector,
      has_text: opts[:hasText],
      has_not_text: opts[:hasNotText],
      has: opts[:has],
      has_not: opts[:hasNot]
    )
  end

  # upstream: _frame.py:672
  def get_by_alt_text(self, text, opts \\ []),
    do: locator(self, Locator.get_by_alt_text_selector(text, exact: opts[:exact]))

  # upstream: _frame.py:677
  def get_by_label(self, text, opts \\ []),
    do: locator(self, Locator.get_by_label_selector(text, exact: opts[:exact]))

  # upstream: _frame.py:682
  def get_by_placeholder(self, text, opts \\ []),
    do: locator(self, Locator.get_by_placeholder_selector(text, exact: opts[:exact]))

  # upstream: _frame.py:687
  def get_by_role(self, role, opts \\ []) do
    locator(
      self,
      Locator.get_by_role_selector(role,
        checked: opts[:checked],
        disabled: opts[:disabled],
        expanded: opts[:expanded],
        includeHidden: opts[:includeHidden],
        level: opts[:level],
        name: opts[:name],
        pressed: opts[:pressed],
        selected: opts[:selected],
        exact: opts[:exact],
        description: opts[:description]
      )
    )
  end

  # upstream: _frame.py:717
  def get_by_test_id(self, testId),
    do: locator(self, Locator.get_by_test_id_selector(Locator.test_id_attribute_name(), testId))

  # upstream: _frame.py:720
  def get_by_text(self, text, opts \\ []),
    do: locator(self, Locator.get_by_text_selector(text, exact: opts[:exact]))

  # upstream: _frame.py:725
  def get_by_title(self, text, opts \\ []),
    do: locator(self, Locator.get_by_title_selector(text, exact: opts[:exact]))

  # upstream: _frame.py:738
  def text_content(self, selector, opts \\ []),
    do:
      Channel.send(
        self[:_channel],
        "textContent",
        &_timeout(self, &1),
        locals_to_params(binding())
      )

  # upstream: _frame.py:798
  def select_option(self, selector, opts \\ []) do
    params =
      locals_to_params(
        [selector: selector, timeout: opts[:timeout], strict: opts[:strict], force: opts[:force]] ++
          ElementHandle.convert_select_option_values(
            opts[:value],
            opts[:index],
            opts[:label],
            opts[:element]
          )
      )

    Channel.send(self[:_channel], "selectOption", &_timeout(self, &1), params)
  end

  # upstream: _frame.py:831
  def set_input_files(self, selector, files, opts \\ []) do
    converted = SetInputFilesHelpers.convert_input_files(files, Page.context(page(self)))

    Channel.send(
      self[:_channel],
      "setInputFiles",
      &_timeout(self, &1),
      Map.merge(
        %{
          "selector" => selector,
          "strict" => opts[:strict],
          "timeout" => _timeout(self, opts[:timeout])
        },
        converted
      )
    )
  end

  # upstream: _frame.py:902
  def check(self, selector, opts \\ []) do
    Channel.send(self[:_channel], "check", &_timeout(self, &1), locals_to_params(binding()))
  end

  # upstream: _frame.py:915
  def uncheck(self, selector, opts \\ []) do
    Channel.send(self[:_channel], "uncheck", &_timeout(self, &1), locals_to_params(binding()))
  end

  # upstream: _frame.py:948
  def title(self), do: Channel.send(self[:_channel], "title", nil)
end
