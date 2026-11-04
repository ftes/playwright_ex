# upstream: playwright/_impl/_helper.py (subset)
alias Playwright.Impl.Errors.{Error, TimeoutError, TargetClosedError}

defmodule Playwright.Impl.Helper do
  @default_playwright_timeout_in_milliseconds 30000
  @default_playwright_launch_timeout_in_milliseconds 180_000
  def default_playwright_timeout_in_milliseconds, do: @default_playwright_timeout_in_milliseconds

  def default_playwright_launch_timeout_in_milliseconds,
    do: @default_playwright_launch_timeout_in_milliseconds

  # upstream: _helper.py:156
  def url_matches(base_url, url_string, match, websocket_url \\ nil) do
    cond do
      !match ->
        true

      is_binary(match) ->
        match = Regex.compile!(resolve_glob_to_regex_pattern(base_url, match, websocket_url))
        Regex.match?(match, url_string)

      is_struct(match, Regex) ->
        Regex.match?(match, url_string)

      true ->
        match.(url_string)
    end
  end

  # upstream: _helper.py:173
  def resolve_glob_to_regex_pattern(_base_url, glob, _websocket_url \\ nil) do
    # (to_websocket_base_url / resolve_glob_base omitted in prototype)
    Playwright.Impl.Glob.glob_to_regex_pattern(glob)
  end

  # upstream: _helper.py:353
  def parse_error(error, log \\ nil) do
    base_error_class = Error

    base_error_class =
      if error["name"] == "TimeoutError", do: TimeoutError, else: base_error_class

    base_error_class =
      if error["name"] == "TargetClosedError", do: TargetClosedError, else: base_error_class

    log = if !log, do: "", else: log
    exc = base_error_class.new(patch_error_message(error["message"]) <> log)
    exc = %{exc | _name: error["name"]}
    exc = %{exc | _stack: error["stack"]}
    exc
  end

  # upstream: _helper.py:367
  def patch_error_message(message) do
    message =
      case Regex.run(~r/^(\w+)(: expected .*)/s, message) do
        [_, g1, g2] -> to_snake_case(g1) <> g2
        nil -> message
      end

    message =
      String.replace(message, "Pass { acceptDownloads: true }", "Pass 'accept_downloads=True'")

    message
  end

  # upstream: _helper.py:377
  def locals_to_params(args) do
    # locals() == binding(): drop `self`, splat the `opts` (kwargs) variable.
    args =
      Enum.flat_map(args, fn
        {:opts, opts} -> opts
        kv -> [kv]
      end)

    for {key, value} <- args, key != :self, value != nil do
      {key,
       if(is_map(value) and not is_struct(value),
         do: Map.new(locals_to_params(Map.to_list(value))),
         else: value
       )}
    end
  end

  # upstream: _helper.py:391
  def monotonic_time, do: System.monotonic_time(:millisecond)

  # upstream: _helper.py:395
  def create_task_and_ignore_exception(_loop, coro) do
    ignore_exception = fn ->
      try do
        coro.()
      rescue
        _ -> nil
      end
    end

    Asyncio.create_task(ignore_exception)
  end

  # upstream: _helper.py:531
  def to_snake_case(name) do
    Regex.replace(~r/((?<=[a-z0-9])[A-Z]|(?!^)[A-Z](?=[a-z]))/, name, "_\\1") |> String.downcase()
  end

  # upstream: _helper.py:535
  def make_dirs_for_file(path) do
    path = if Path.type(path) != :absolute, do: Path.join(File.cwd!(), path), else: path
    File.mkdir_p!(Path.dirname(path))
  end
end

defmodule Playwright.Impl.Helper.TimeoutSettings do
  use Py
  alias Playwright.Impl.Helper

  # upstream: _helper.py:300 (@staticmethod)
  def launch_timeout(timeout \\ nil) do
    if timeout != nil,
      do: timeout,
      else: Helper.default_playwright_launch_timeout_in_milliseconds()
  end

  # upstream: _helper.py:307
  def init(parent) do
    self = Py.new(__MODULE__)
    Py.set(self, :_parent, parent)
    Py.set(self, :_default_timeout, nil)
    Py.set(self, :_default_navigation_timeout, nil)
    self
  end

  # upstream: _helper.py:312
  def set_default_timeout(self, timeout), do: Py.set(self, :_default_timeout, timeout)

  # upstream: _helper.py:315
  def timeout(self, timeout \\ nil) do
    cond do
      timeout != nil -> timeout
      self[:_default_timeout] != nil -> self[:_default_timeout]
      self[:_parent] -> timeout(self[:_parent])
      true -> Helper.default_playwright_timeout_in_milliseconds()
    end
  end

  # upstream: _helper.py:324
  def set_default_navigation_timeout(self, navigation_timeout),
    do: Py.set(self, :_default_navigation_timeout, navigation_timeout)

  # upstream: _helper.py:329
  def default_navigation_timeout(self), do: self[:_default_navigation_timeout]

  # upstream: _helper.py:332
  def default_timeout(self), do: self[:_default_timeout]

  # upstream: _helper.py:335
  def navigation_timeout(self, timeout \\ nil) do
    cond do
      timeout != nil -> timeout
      self[:_default_navigation_timeout] != nil -> self[:_default_navigation_timeout]
      self[:_default_timeout] != nil -> self[:_default_timeout]
      self[:_parent] -> navigation_timeout(self[:_parent])
      true -> Helper.default_playwright_timeout_in_milliseconds()
    end
  end
end
