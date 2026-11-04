# upstream: playwright/_impl/_locator.py (subset)
defmodule Playwright.Impl.Locator do
  # class Locator: immutable after __init__ -> plain struct (no heap).
  defstruct [:_frame, :_selector, :_loop, :_dispatcher_fiber, :_locator_code]
  alias Playwright.Impl.Frame
  alias Playwright.Impl.Errors.Error
  import Playwright.Impl.Helper, only: [locals_to_params: 1]

  import Playwright.Impl.StrUtils,
    only: [escape_for_attribute_selector: 2, escape_for_text_selector: 2]

  # upstream: _locator.py:69
  def init(frame, selector, opts \\ []) do
    self = %__MODULE__{_frame: frame, _selector: selector}
    self = %{self | _loop: frame[:_loop]}
    self = %{self | _dispatcher_fiber: frame[:_connection][:_dispatcher_fiber]}
    # Python code for this locator, known only for normalized locators.
    self = %{self | _locator_code: nil}

    self =
      if opts[:has_text],
        do: %{
          self
          | _selector:
              self._selector <>
                " >> internal:has-text=#{escape_for_text_selector(opts[:has_text], false)}"
        },
        else: self

    self =
      if has = opts[:has] do
        if has._frame != frame,
          do: raise(Error.new(~s(Inner "has" locator must belong to the same frame.)))

        %{self | _selector: self._selector <> " >> internal:has=" <> JSON.encode!(has._selector)}
      else
        self
      end

    self =
      if opts[:has_not_text],
        do: %{
          self
          | _selector:
              self._selector <>
                " >> internal:has-not-text=#{escape_for_text_selector(opts[:has_not_text], false)}"
        },
        else: self

    self =
      if locator = opts[:has_not] do
        if locator._frame != frame,
          do: raise(Error.new(~s(Inner "has_not" locator must belong to the same frame.)))

        %{
          self
          | _selector:
              self._selector <> " >> internal:has-not=" <> JSON.encode!(locator._selector)
        }
      else
        self
      end

    self =
      if opts[:visible] != nil,
        do: %{
          self
          | _selector: self._selector <> " >> visible=#{bool_to_js_bool(opts[:visible])}"
        },
        else: self

    self
  end

  # upstream: _locator.py:134
  def _equals(self, locator),
    do: self._frame == locator._frame and self._selector == locator._selector

  # upstream: _locator.py:138
  def page(self), do: Frame.page(self._frame)

  # upstream: _locator.py:147
  def check(self, opts \\ []) do
    params = locals_to_params(binding())
    Frame.check(self._frame, self._selector, [strict: true] ++ params)
  end

  # upstream: _locator.py:159
  def click(self, opts \\ []) do
    params = locals_to_params(binding())
    Frame._click(self._frame, self._selector, [strict: true] ++ params)
  end

  # upstream: _locator.py:220
  def fill(self, value, opts \\ []) do
    params = locals_to_params(binding()) |> Keyword.delete(:value)
    Frame.fill(self._frame, self._selector, value, [strict: true] ++ params)
  end

  # upstream: _locator.py:239
  def locator(self, selector_or_locator, opts \\ []) do
    # (Locator-argument branch omitted)
    init(self._frame, "#{self._selector} >> #{selector_or_locator}",
      has_text: opts[:hasText],
      has_not_text: opts[:hasNotText],
      has_not: opts[:hasNot],
      has: opts[:has]
    )
  end

  # upstream: _locator.py:273
  def get_by_label(self, text, opts \\ []),
    do: locator(self, get_by_label_selector(text, exact: opts[:exact]))

  # upstream: _locator.py:313
  def get_by_test_id(self, testId),
    do: locator(self, get_by_test_id_selector(test_id_attribute_name(), testId))

  # upstream: _locator.py:641
  def select_option(self, value \\ nil, opts \\ []) do
    params = locals_to_params(binding())
    Frame.select_option(self._frame, self._selector, [strict: true] ++ params)
  end

  # upstream: _locator.py:665
  def set_input_files(self, files, opts \\ []) do
    params = locals_to_params(binding()) |> Keyword.delete(:files)
    Frame.set_input_files(self._frame, self._selector, files, [strict: true] ++ params)
  end

  # upstream: _locator.py:701
  def text_content(self, opts \\ []) do
    params = locals_to_params(binding())
    Frame.text_content(self._frame, self._selector, [strict: true] ++ params)
  end

  # upstream: _locator.py:816
  def _expect(self, expression, options, title \\ nil),
    do: Frame._expect(self._frame, self._selector, expression, options, title)

  # upstream: _locator.py:963
  def test_id_attribute_name,
    do: :persistent_term.get({__MODULE__, :_test_id_attribute_name}, "data-testid")

  # upstream: _locator.py:967
  def set_test_id_attribute_name(attribute_name),
    do: :persistent_term.put({__MODULE__, :_test_id_attribute_name}, attribute_name)

  # upstream: _locator.py:972
  def get_by_test_id_selector(test_id_attribute_name, test_id),
    do:
      "internal:testid=[#{test_id_attribute_name}=#{escape_for_attribute_selector(test_id, true)}]"

  # upstream: _locator.py:978
  def get_by_attribute_text_selector(attr_name, text, opts \\ []),
    do: "internal:attr=[#{attr_name}=#{escape_for_attribute_selector(text, opts[:exact])}]"

  # upstream: _locator.py:984
  def get_by_label_selector(text, opts \\ []),
    do: "internal:label=" <> escape_for_text_selector(text, opts[:exact])

  # upstream: _locator.py:988
  def get_by_alt_text_selector(text, opts \\ []),
    do: get_by_attribute_text_selector("alt", text, exact: opts[:exact])

  # upstream: _locator.py:992
  def get_by_title_selector(text, opts \\ []),
    do: get_by_attribute_text_selector("title", text, exact: opts[:exact])

  # upstream: _locator.py:996
  def get_by_placeholder_selector(text, opts \\ []),
    do: get_by_attribute_text_selector("placeholder", text, exact: opts[:exact])

  # upstream: _locator.py:1002
  def get_by_text_selector(text, opts \\ []),
    do: "internal:text=" <> escape_for_text_selector(text, opts[:exact])

  # upstream: _locator.py:1006
  def bool_to_js_bool(value), do: if(value, do: "true", else: "false")

  # upstream: _locator.py:1010
  def get_by_role_selector(role, opts \\ []) do
    props = []

    props =
      if opts[:checked] != nil,
        do: props ++ [{"checked", bool_to_js_bool(opts[:checked])}],
        else: props

    props =
      if opts[:disabled] != nil,
        do: props ++ [{"disabled", bool_to_js_bool(opts[:disabled])}],
        else: props

    props =
      if opts[:selected] != nil,
        do: props ++ [{"selected", bool_to_js_bool(opts[:selected])}],
        else: props

    props =
      if opts[:expanded] != nil,
        do: props ++ [{"expanded", bool_to_js_bool(opts[:expanded])}],
        else: props

    props =
      if opts[:includeHidden] != nil,
        do: props ++ [{"include-hidden", bool_to_js_bool(opts[:includeHidden])}],
        else: props

    props = if opts[:level] != nil, do: props ++ [{"level", to_string(opts[:level])}], else: props

    props =
      if opts[:name] != nil,
        do: props ++ [{"name", escape_for_attribute_selector(opts[:name], opts[:exact])}],
        else: props

    props =
      if opts[:description] != nil,
        do:
          props ++
            [{"description", escape_for_attribute_selector(opts[:description], opts[:exact])}],
        else: props

    props =
      if opts[:pressed] != nil,
        do: props ++ [{"pressed", bool_to_js_bool(opts[:pressed])}],
        else: props

    props_str = Enum.map_join(props, fn {k, v} -> "[#{k}=#{v}]" end)
    "internal:role=#{role}#{props_str}"
  end
end
