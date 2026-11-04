# SelectOptionValueProtocol / FrameNavigatedEventArgs live at the bottom of Frame.cs; Elixir needs
# struct modules compiled before use, so they come first here.
defmodule Playwright.Core.SelectOptionValueProtocol do
  @moduledoc "upstream: Core/Frame.cs:1187 (class SelectOptionValueProtocol)"
  defstruct [:value, :value_or_label, :label, :index]

  # upstream: Core/Frame.cs:1200
  def from(value), do: struct(__MODULE__, Map.take(Map.new(value), [:value, :label, :index]))

  def to_json(%__MODULE__{} = v),
    do: Playwright.Transport.Converters.drop_nils(%{"value" => v.value, "valueOrLabel" => v.value_or_label, "label" => v.label, "index" => v.index})
end

defmodule Playwright.Core.FrameNavigatedEventArgs do
  @moduledoc "upstream: Core/Frame.cs:1211 (class FrameNavigatedEventArgs)"
  defstruct [:name, :url, :error, :new_document]

  def from_json(json, _connection), do: %__MODULE__{name: json["name"], url: json["url"], error: json["error"]}
end

defmodule Playwright.Core.Frame do
  @moduledoc "upstream: Core/Frame.cs"
  use Playwright.Transport.ChannelOwner, [:parent_frame]

  alias Playwright.Core.BrowserContext
  alias Playwright.Core.Locator
  alias Playwright.Core.Page
  alias Playwright.Core.PageEvent
  alias Playwright.Core.Request
  alias Playwright.Core.SelectOptionValueProtocol
  alias Playwright.Core.FrameNavigatedEventArgs
  alias Playwright.Core.ScriptsHelper
  alias Playwright.Core.TimeoutSettings
  alias Playwright.Core.Waiter
  alias Playwright.Helpers.SetInputFilesHelpers
  alias Playwright.Helpers.URLMatch
  alias Playwright.PlaywrightException
  alias Playwright.Transport.ChannelOwner
  alias Playwright.Transport.Connection
  alias Playwright.Transport.Converters
  alias Playwright.Transport.Protocol.FrameExpectResult
  import ChannelOwner, only: [get: 2, set: 3, update: 3, emit: 3]

  # upstream: Core/Frame.cs:48
  def new(parent, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, guid, parent_frame: initializer.parent_frame)
    set(this, :url, initializer.url)
    set(this, :name, initializer.name)
    set(this, :load_states, initializer.load_states)
    set(this, :child_frames, [])
    # skipped: Webmcp = new WebMCP(this);
    this
  end

  # events (Frame.cs:60 Navigated, :65 LoadState) have no function: emit(this, "Navigated" | "LoadState", _)

  # upstream: Core/Frame.cs:67
  def child_frames(this), do: get(this, :child_frames)

  # upstream: Core/Frame.cs:69
  def name(this), do: get(this, :name)

  # upstream: Core/Frame.cs:71
  def url(this), do: get(this, :url)

  # upstream: Core/Frame.cs:75
  def parent_frame(this), do: this.parent_frame

  # upstream: Core/Frame.cs:77
  def page(this), do: get(this, :page)

  # upstream: Core/Frame.cs:79
  def is_detached(this), do: get(this, :is_detached) == true

  # upstream: Core/Frame.cs:83
  @impl true
  def on_message(this, method, server_params) do
    case method do
      "navigated" ->
        e = FrameNavigatedEventArgs.from_json(server_params, this.connection)

        e = if Map.has_key?(server_params, "newDocument") do
          %{e | new_document: %{request: Converters.to_channel_owner(server_params["newDocument"]["request"], this.connection)}}
        else
          e
        end

        on_navigated(this, e)
      "loadstate" ->
        add = Converters.to_enum(server_params["add"])
        remove = Converters.to_enum(server_params["remove"])
        on_load_state(this, add, remove)
      _ ->
        :ok
    end
  end

  # upstream: Core/Frame.cs:113
  def on_load_state(this, add, remove) do
    if add != nil do
      update(this, :load_states, &(&1 ++ [add]))
      emit(this, "LoadState", add)
    end

    if remove != nil do
      update(this, :load_states, &List.delete(&1, remove))
    end
    if this.parent_frame == nil and add == :load and page(this) != nil do
      Page.fire_load(page(this))
    end
    if this.parent_frame == nil and add == :domcontentloaded and page(this) != nil do
      Page.fire_dom_content_loaded(page(this))
    end
  end

  # upstream: Core/Frame.cs:135
  def on_navigated(this, e) do
    set(this, :url, e.url)
    set(this, :name, e.name)
    emit(this, "Navigated", e)

    if e.error in [nil, ""] do
      if page(this), do: Page.on_frame_navigated(page(this), this)
    end
  end

  # upstream: Core/Frame.cs:147
  def timeout(this, timeout) do
    timeout_settings = (page(this) && page(this).timeout_settings) || TimeoutSettings.new()
    TimeoutSettings.timeout(timeout_settings, timeout)
  end

  # upstream: Core/Frame.cs:153
  def navigation_timeout(this, timeout) do
    timeout_settings = (page(this) && page(this).timeout_settings) || TimeoutSettings.new()
    TimeoutSettings.navigation_timeout(timeout_settings, timeout)
  end

  # upstream: Core/Frame.cs:168
  def title_async(this), do: ChannelOwner.send_message_to_server(this, "title")["value"]

  # upstream: Core/Frame.cs:180 + :184 + :205 + :209 (string | [string] | SelectOptionValue overloads)
  def select_option_async(this, selector, values, options \\ nil)
  def select_option_async(this, selector, values, options) when is_binary(values), do: select_option_async(this, selector, [values], options)

  def select_option_async(this, selector, values, options) do
    values = Enum.map(values, fn
      value_or_label when is_binary(value_or_label) -> %SelectOptionValueProtocol{value_or_label: value_or_label}
      value -> SelectOptionValueProtocol.from(value)
    end)
    select_option_protocol_async(this, selector, values, options)
  end

  # upstream: Core/Frame.cs:212
  defp select_option_protocol_async(this, selector, values, options) do
    ChannelOwner.send_message_to_server(
      this,
      "selectOption",
      %{
        "selector" => selector,
        "options" => values,
        "noWaitAfter" => options[:no_wait_after],
        "strict" => options[:strict],
        "force" => options[:force],
      },
      timeout: timeout(this, options[:timeout]))["values"]
  end

  # upstream: Core/Frame.cs:228
  def wait_for_load_state_async(this, state \\ nil, options \\ nil) do
    load_state =
      case state do
        :load -> :load
        :domcontentloaded -> :domcontentloaded
        :networkidle -> :networkidle
        _ -> :load
      end
    waiter = setup_navigation_waiter(this, "frame.WaitForLoadStateAsync", options[:timeout])
    try do
      if load_state in get(this, :load_states) do
        Waiter.log(waiter, "  not waiting, \"#{state}\" event already fired")
      else
        Waiter.wait_for_event_async(waiter, this, "LoadState", fn s ->
          Waiter.log(waiter, "  \"#{s}\" event fired")
          s == load_state
        end).()
      end
    after
      Waiter.dispose(waiter)
    end
    :ok
  end

  # upstream: Core/Frame.cs:268
  def wait_for_navigation_async(this, options \\ nil) do
    run_and_wait_for_navigation_async(this, nil,
      url: options[:url],
      wait_until: options[:wait_until],
      timeout: options[:timeout])
  end

  # upstream: Core/Frame.cs:282
  def run_and_wait_for_navigation_async(this, action, options \\ nil) do
    waiter = setup_navigation_waiter(this, "frame.WaitForNavigationAsync", options[:timeout])
    try do
      result = wait_for_navigation_internal_async(this, waiter, options[:url], options[:wait_until])

      if action != nil do
        Waiter.cancel_wait_on_exception_async(waiter, result, action)
      end

      result.()
    after
      Waiter.dispose(waiter)
    end
  end

  # upstream: Core/Frame.cs:295 (url: string glob | Regex | fun collapses urlString/urlRegex/urlFunc)
  defp wait_for_navigation_internal_async(this, waiter, url, wait_until) do
    wait_until = wait_until || :load
    to_url = if is_binary(url) and url != "", do: " to \"#{url}\"", else: ""

    Waiter.log(waiter, "waiting for navigation#{to_url} until \"#{wait_until}\"")

    navigated_event_task = Waiter.wait_for_event_async(
      waiter,
      this,
      "Navigated",
      fn e ->
        # Any failed navigation results in a rejection.
        if e.error != nil do
          true
        else
          Waiter.log(waiter, "  navigated to \"#{e.url}\"")
          URLMatch.match(url_match(this, url), e.url)
        end
      end)

    # C# returns here with a hot Task; the rest runs when awaited.
    fn ->
      navigated_event = navigated_event_task.()

      if navigated_event.error != nil do
        ex = PlaywrightException.new(navigated_event.error)
        Waiter.wait_for_promise_async(waiter, {:exception, ex})
      end

      if wait_until not in get(this, :load_states) do
        Waiter.wait_for_event_async(
          waiter,
          this,
          "LoadState",
          fn e ->
            Waiter.log(waiter, "  \"#{e}\" event fired")
            e == wait_until
          end).()
      end

      request = navigated_event.new_document && navigated_event.new_document.request

      if request != nil do
        Waiter.wait_for_promise_async(waiter, Waiter.async(fn -> Request.response_async(Request.final_request(request)) end))
      else
        nil
      end
    end
  end

  # upstream: Core/Frame.cs:510
  def fill_async(this, selector, value, options \\ nil) do
    ChannelOwner.send_message_to_server(
      this,
      "fill",
      %{
        "selector" => selector,
        "value" => value,
        "force" => options[:force],
        "strict" => options[:strict],
      },
      timeout: timeout(this, options[:timeout]))
    :ok
  end

  # upstream: Core/Frame.cs:559 + :563 (string | [string]); FilePayload overloads :572 + :576
  def set_input_files_async(this, selector, files, options \\ nil)
  def set_input_files_async(this, selector, files, options) when is_binary(files) or is_map(files),
    do: set_input_files_async(this, selector, [files], options)

  def set_input_files_async(this, selector, [%{buffer: _} | _] = files, options) do
    converted = SetInputFilesHelpers.convert_input_files(files)
    set_input_files_internal_async(this, selector, converted, options[:no_wait_after], options[:timeout], options[:strict])
  end

  def set_input_files_async(this, selector, files, options) do
    converted = SetInputFilesHelpers.convert_input_files_async(files, Page.context(page(this)))
    set_input_files_internal_async(this, selector, converted, options[:no_wait_after], options[:timeout], options[:strict])
  end

  # upstream: Core/Frame.cs:584
  defp set_input_files_internal_async(this, selector, files, _no_wait_after, timeout, strict) do
    ChannelOwner.send_message_to_server(
      this,
      "setInputFiles",
      %{
        "selector" => selector,
        "payloads" => files.payloads,
        "localPaths" => files.local_paths,
        "localDirectory" => files.local_directory,
        "streams" => files.streams,
        "directoryStream" => files.directory_stream,
        "strict" => strict,
      },
      timeout: timeout(this, timeout))
    :ok
  end

  # upstream: Core/Frame.cs:602
  def click_async(this, selector, options \\ nil), do: click_internal_async(this, selector, options, nil)

  # upstream: Core/Frame.cs:605
  def click_internal_async(this, selector, options, steps) do
    ChannelOwner.send_message_to_server(
      this,
      "click",
      %{
        "selector" => selector,
        "button" => options[:button],
        "force" => options[:force],
        "scroll" => options[:scroll],
        "delay" => options[:delay],
        "clickCount" => options[:click_count],
        "modifiers" => options[:modifiers],
        "position" => options[:position],
        "noWaitAfter" => options[:no_wait_after],
        "steps" => steps,
        "trial" => options[:trial],
        "strict" => options[:strict],
      },
      timeout: timeout(this, options[:timeout]))
    :ok
  end

  # upstream: Core/Frame.cs:650
  def check_async(this, selector, options \\ nil) do
    ChannelOwner.send_message_to_server(
      this,
      "check",
      %{
        "selector" => selector,
        "force" => options[:force],
        "scroll" => options[:scroll],
        "position" => options[:position],
        "trial" => options[:trial],
        "strict" => options[:strict],
      },
      timeout: timeout(this, options[:timeout]))
    :ok
  end

  # upstream: Core/Frame.cs:847
  def locator(this, selector, options \\ nil),
    do: Locator.new(this, selector,
      has: options[:has],
      has_not: options[:has_not],
      has_text: options[:has_text],
      has_not_text: options[:has_not_text])

  # upstream: Core/Frame.cs:871
  def goto_async(this, url, options \\ nil) do
    ChannelOwner.send_message_to_server(
      this,
      "goto",
      %{
        "url" => url,
        "waitUntil" => options[:wait_until],
        "referer" => options[:referer],
      },
      timeout: navigation_timeout(this, options[:timeout]), as: Playwright.Core.Response)
  end

  # upstream: Core/Frame.cs:943 + :947 + :951 (string | Regex | fun) -> private :1060
  def wait_for_url_async(this, url, options \\ nil) do
    if URLMatch.match(url_match(this, url), url(this)) do
      wait_for_load_state_async(this, to_load_state(options[:wait_until]), timeout: options[:timeout])
    else
      wait_for_navigation_async(this,
        url: url,
        timeout: options[:timeout],
        wait_until: options[:wait_until])
    end
    :ok
  end

  # upstream: Core/Frame.cs:1005
  def expect_async(this, selector, expression, options) do
    try do
      ChannelOwner.send_message_to_server(
        this,
        "expect",
        %{
          "selector" => selector,
          "expression" => expression,
          "expressionArg" => options.expression_arg,
          "expectedText" => options.expected_text,
          "expectedNumber" => options.expected_number,
          "expectedValue" => options.expected_value,
          "useInnerText" => options.use_inner_text,
          "isNot" => options.is_not,
        },
        timeout: options.timeout)
      %FrameExpectResult{matches: !options.is_not}
    rescue
      e in [PlaywrightException, Playwright.TimeoutException, Playwright.TargetClosedException] ->
        if !Map.has_key?(e.data, Connection.error_details_data_key()), do: reraise(e, __STACKTRACE__)
        result = %FrameExpectResult{
          matches: options.is_not,
          log: e.data[Connection.log_data_key()] || [],
        }
        details = e.data[Connection.error_details_data_key()]
        if is_map(details) do
          result = if is_binary(details["customErrorMessage"]) do
            %{result | error_message: "Error: " <> details["customErrorMessage"]}
          else
            result
          end
          if is_map(details["received"]) do
            received = details["received"]
            result = if Map.has_key?(received, "value"), do: %{result | received: ScriptsHelper.parse_evaluate_result(received["value"])}, else: result
            if is_binary(received["ariaSnapshot"]), do: %{result | received_aria_snapshot: received["ariaSnapshot"]}, else: result
          else
            result
          end
        else
          result
        end
    end
  end

  # (url_match: `new URLMatch { glob, re, func, baseURL }` built from one Elixir value)
  defp url_match(this, url) do
    %URLMatch{
      glob: if(is_binary(url), do: url),
      re: if(is_struct(url, Regex), do: url),
      func: if(is_function(url), do: url),
      base_url: page(this) && BrowserContext.base_url(Page.context(page(this)))
    }
  end

  # upstream: Core/Frame.cs:1084
  defp to_load_state(wait_until_state) do
    case wait_until_state do
      nil -> nil
      :load -> :load
      :domcontentloaded -> :domcontentloaded
      :networkidle -> :networkidle
      _ -> nil
    end
  end

  # upstream: Core/Frame.cs:1100
  defp setup_navigation_waiter(this, event, timeout) do
    waiter = Waiter.new(page(this), event)
    if Page.is_closed(page(this)) do
      Waiter.reject_immediately(waiter, Page.close_error_with_reason(page(this)))
    end
    Waiter.reject_on_event(waiter, page(this), PageEvent.close().name, fn -> Page.close_error_with_reason(page(this)) end)
    Waiter.reject_on_event(waiter, page(this), PageEvent.crash().name, PlaywrightException.new("Navigation failed because page was crashed!"))
    Waiter.reject_on_event(
      waiter,
      page(this),
      "FrameDetached",
      PlaywrightException.new("Navigating frame was detached!"),
      fn e -> e == this end)
    timeout = TimeoutSettings.navigation_timeout(page(this).timeout_settings, timeout)
    Waiter.reject_on_timeout(waiter, trunc(timeout), "Timeout #{timeout}ms exceeded.")

    waiter
  end

  # upstream: Core/Frame.cs:1142 + :1146
  def get_by_label(this, text, options \\ nil),
    do: locator(this, Locator.get_by_label_selector(text, options[:exact]))

  # upstream: Core/Frame.cs:1158
  def get_by_role(this, role, options \\ nil),
    do: locator(this, Locator.get_by_role_selector(role, options || []))

  # upstream: Core/Frame.cs:1162 + :1166
  def get_by_test_id(this, test_id),
    do: locator(this, Locator.get_by_test_id_selector(Locator.test_id_attribute_name(), test_id))
end
