# upstream: playwright/_impl/_assertions.py (subset)
# Decision: AssertionsBase -> PageAssertions/LocatorAssertions inheritance becomes
# plain structs + a shared AssertionsBase module; the virtual `_call_expect` is
# dispatched via `self.__struct__`. Python's AssertionError -> ExUnit.AssertionError.
alias Playwright.Impl.Assertions
alias Playwright.Impl.Assertions.AssertionsBase
alias Playwright.Impl.{Connection, Frame, JSHandle, Locator, Page, StrUtils}
alias Playwright.Impl.Errors.Error

defmodule Playwright.Impl.Assertions.AssertionsBase do
  @fields [
    :_actual_locator,
    :_loop,
    :_dispatcher_fiber,
    :_timeout,
    :_is_not,
    :_custom_message,
    :_is_soft
  ]
  def fields, do: @fields

  # upstream: _assertions.py:64
  def init(self, locator, timeout \\ nil, is_not \\ false, message \\ nil, is_soft \\ false) do
    self = %{self | _actual_locator: locator}
    self = %{self | _loop: locator._loop}
    self = %{self | _dispatcher_fiber: locator._dispatcher_fiber}
    self = %{self | _timeout: timeout}
    self = %{self | _is_not: is_not}
    self = %{self | _custom_message: message}
    self = %{self | _is_soft: is_soft}
    self
  end

  # upstream: _assertions.py:87
  def _expect_impl(self, expression, expect_options, expected, message, title \\ nil) do
    expect_options = Map.put(expect_options, "isNot", self._is_not)

    expect_options =
      if expect_options["timeout"] == nil,
        do: Map.put(expect_options, "timeout", self._timeout || 5_000),
        else: expect_options

    {message, title} =
      if expect_options["isNot"] do
        message = String.replace(message, "expected to", "expected not to")
        title = if title, do: String.replace(title, ~s("to_), ~s("not_to_)), else: title
        {message, title}
      else
        {message, title}
      end

    expect_options =
      if Map.has_key?(expect_options, "useInnerText") and expect_options["useInnerText"] == nil,
        do: Map.delete(expect_options, "useInnerText"),
        else: expect_options

    result = self.__struct__._call_expect(self, expression, expect_options, title)

    if result["matches"] == self._is_not do
      received = result["received"] || %{}
      aria_snapshot = nil

      {aria_snapshot, actual} =
        if is_map(received) do
          aria_snapshot = received["ariaSnapshot"]
          value = received["value"]
          actual = if value != nil, do: JSHandle.parse_value(value), else: nil
          {aria_snapshot, actual}
        else
          {aria_snapshot, received}
        end

      out_message =
        if self._custom_message do
          out_message = self._custom_message

          if expected != nil,
            do: out_message <> "\nExpected value: '#{expected || "<None>"}'",
            else: out_message
        else
          if expected != nil, do: "#{message} '#{format(expected)}'", else: "#{message}"
        end

      error_message = result["errorMessage"]
      error_message = if error_message, do: "\n#{error_message}", else: ""
      aria_snapshot_message = if aria_snapshot, do: "\nAria snapshot:\n#{aria_snapshot}", else: ""

      Assertions._record_soft_or_raise(
        %ExUnit.AssertionError{
          message:
            "#{out_message}\nActual value: #{format(actual)}#{error_message} #{Connection.format_call_log(result["log"])}#{aria_snapshot_message}"
        },
        self._is_soft
      )
    end

    nil
  end

  # str() of the expected/actual values (Python prints re.Pattern as re.compile('...'))
  defp format(%Regex{} = r), do: inspect(r)
  defp format(v), do: to_string(v)
end

defmodule Playwright.Impl.Assertions.PageAssertions do
  defstruct AssertionsBase.fields() ++ [:_actual_page]

  # upstream: _assertions.py:137
  def init(page, timeout \\ nil, is_not \\ false, message \\ nil, is_soft \\ false) do
    self =
      AssertionsBase.init(
        %__MODULE__{},
        Page.locator(page, ":root"),
        timeout,
        is_not,
        message,
        is_soft
      )

    self = %{self | _actual_page: page}
    self
  end

  # upstream: _assertions.py:148
  def _call_expect(self, expression, expect_options, title),
    do: Frame._expect(Page.main_frame(self._actual_page), nil, expression, expect_options, title)

  # upstream: _assertions.py:157
  def _not(self),
    do:
      init(
        self._actual_page,
        self._timeout,
        not self._is_not,
        self._custom_message,
        self._is_soft
      )

  # upstream: _assertions.py:166
  def to_have_title(self, titleOrRegExp, timeout \\ nil) do
    expected_values = Assertions.to_expected_text_values([titleOrRegExp], false, true)

    AssertionsBase._expect_impl(
      self,
      "to.have.title",
      %{"expectedText" => expected_values, "timeout" => timeout},
      titleOrRegExp,
      "Page title expected to be",
      ~s(Expect "to_have_title")
    )
  end

  # upstream: _assertions.py:181
  def not_to_have_title(self, titleOrRegExp, timeout \\ nil),
    do: to_have_title(_not(self), titleOrRegExp, timeout)

  # upstream: _assertions.py:187
  def to_have_url(self, urlOrRegExp, timeout \\ nil, ignoreCase \\ nil) do
    base_url = Page.context(self._actual_page)[:_base_url]

    urlOrRegExp =
      if is_binary(urlOrRegExp) and base_url,
        do: URI.merge(base_url, urlOrRegExp) |> to_string(),
        else: urlOrRegExp

    expected_text = Assertions.to_expected_text_values([urlOrRegExp], false, false, ignoreCase)

    AssertionsBase._expect_impl(
      self,
      "to.have.url",
      %{"expectedText" => expected_text, "timeout" => timeout},
      urlOrRegExp,
      "Page URL expected to be",
      ~s(Expect "to_have_url")
    )
  end

  # upstream: _assertions.py:206
  def not_to_have_url(self, urlOrRegExp, timeout \\ nil, ignoreCase \\ nil),
    do: to_have_url(_not(self), urlOrRegExp, timeout, ignoreCase)
end

defmodule Playwright.Impl.Assertions.LocatorAssertions do
  defstruct AssertionsBase.fields()

  # upstream: _assertions.py:235
  def init(locator, timeout \\ nil, is_not \\ false, message \\ nil, is_soft \\ false) do
    self = AssertionsBase.init(%__MODULE__{}, locator, timeout, is_not, message, is_soft)
    self = %{self | _actual_locator: locator}
    self
  end

  # upstream: _assertions.py:246
  def _call_expect(self, expression, expect_options, title),
    do: Locator._expect(self._actual_locator, expression, expect_options, title)

  # upstream: _assertions.py:253
  def _not(self),
    do:
      init(
        self._actual_locator,
        self._timeout,
        not self._is_not,
        self._custom_message,
        self._is_soft
      )

  # upstream: _assertions.py:611
  def to_have_text(self, expected, opts \\ []) do
    if is_list(expected) do
      expected_text = Assertions.to_expected_text_values(expected, false, true, opts[:ignoreCase])

      AssertionsBase._expect_impl(
        self,
        "to.have.text.array",
        %{
          "expectedText" => expected_text,
          "useInnerText" => opts[:useInnerText],
          "timeout" => opts[:timeout]
        },
        expected,
        "Locator expected to have text",
        ~s(Expect "to_have_text")
      )
    else
      expected_text =
        Assertions.to_expected_text_values([expected], false, true, opts[:ignoreCase])

      AssertionsBase._expect_impl(
        self,
        "to.have.text",
        %{
          "expectedText" => expected_text,
          "useInnerText" => opts[:useInnerText],
          "timeout" => opts[:timeout]
        },
        expected,
        "Locator expected to have text",
        ~s(Expect "to_have_text")
      )
    end
  end

  # upstream: _assertions.py:660
  def not_to_have_text(self, expected, opts \\ []), do: to_have_text(_not(self), expected, opts)

  # upstream: _assertions.py:693
  def to_be_checked(self, opts \\ []) do
    expected_value = %{}

    expected_value =
      if opts[:indeterminate] != nil,
        do: Map.put(expected_value, "indeterminate", opts[:indeterminate]),
        else: expected_value

    expected_value =
      if opts[:checked] != nil,
        do: Map.put(expected_value, "checked", opts[:checked]),
        else: expected_value

    checked_string =
      if opts[:indeterminate],
        do: "indeterminate",
        else: if(opts[:checked] == false, do: "unchecked", else: "checked")

    AssertionsBase._expect_impl(
      self,
      "to.be.checked",
      %{"timeout" => opts[:timeout], "expectedValue" => expected_value},
      nil,
      "Locator expected to be #{checked_string}",
      ~s(Expect "to_be_checked")
    )
  end

  # upstream: _assertions.py:726
  def not_to_be_checked(self, opts \\ []),
    do: to_be_checked(_not(self), Keyword.take(opts, [:timeout]))
end

defmodule Playwright.Impl.Assertions do
  # upstream: _assertions.py:49
  def _record_soft_or_raise(error, is_soft) do
    if is_soft do
      soft_errors = Process.get(:_soft_errors)

      if soft_errors == nil,
        do:
          raise(
            RuntimeError,
            "expect.soft(...) requires a soft assertion scope; use a regular expect(...) assertion."
          )

      Process.put(:_soft_errors, soft_errors ++ [error])
    else
      raise error
    end
  end

  # upstream: _assertions.py:1079
  def expected_regex(pattern, match_substring, normalize_white_space, ignoreCase \\ nil) do
    expected = %{
      "regexSource" => Regex.source(pattern),
      "regexFlags" => StrUtils.escape_regex_flags(pattern),
      "matchSubstring" => match_substring,
      "normalizeWhiteSpace" => normalize_white_space,
      "ignoreCase" => ignoreCase
    }

    expected =
      if expected["ignoreCase"] == nil, do: Map.delete(expected, "ignoreCase"), else: expected

    expected
  end

  # upstream: _assertions.py:1097
  def to_expected_text_values(
        items,
        match_substring \\ false,
        normalize_white_space \\ false,
        ignoreCase \\ nil
      ) do
    if not is_list(items), do: raise(Error.new("Expected a list or tuple of strings or patterns"))

    for item <- items do
      cond do
        is_binary(item) ->
          o = %{
            "string" => item,
            "matchSubstring" => match_substring,
            "normalizeWhiteSpace" => normalize_white_space,
            "ignoreCase" => ignoreCase
          }

          if o["ignoreCase"] == nil, do: Map.delete(o, "ignoreCase"), else: o

        is_struct(item, Regex) ->
          expected_regex(item, match_substring, normalize_white_space, ignoreCase)

        true ->
          raise Error.new("value must be a string or regular expression")
      end
    end
  end
end
