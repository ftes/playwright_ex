defmodule Playwright.Core.Locator do
  @moduledoc """
  upstream: Core/Locator.cs (not a ChannelOwner: an immutable value -> plain struct).
  C# overloads (string/Regex/IEnumerable) collapse into one function with pattern matching.
  """
  alias Playwright.Core.Frame
  alias Playwright.Helpers.RegexOptionsExtensions

  defstruct [:frame, :selector]

  @test_id_attribute_name "data-testid"

  # upstream: Core/Locator.cs:53
  def new(parent, selector, options \\ nil, visible \\ nil) do
    frame = parent
    selector =
      cond do
        is_struct(options[:has_text], Regex) -> selector <> " >> internal:has-text=#{escape_for_text_selector(options[:has_text], false)}"
        options[:has_text] != nil -> selector <> " >> internal:has-text=#{escape_for_text_selector(options[:has_text], false)}"
        true -> selector
      end

    selector =
      cond do
        is_struct(options[:has_not_text], Regex) -> selector <> " >> internal:has-not-text=#{escape_for_text_selector(options[:has_not_text], false)}"
        options[:has_not_text] != nil -> selector <> " >> internal:has-not-text=#{escape_for_text_selector(options[:has_not_text], false)}"
        true -> selector
      end

    selector =
      if options[:has] != nil do
        locator = options[:has]
        if locator.frame != frame do
          raise ArgumentError, "Inner \"Has\" locator must belong to the same frame."
        end

        selector <> " >> internal:has=" <> JSON.encode!(locator.selector)
      else
        selector
      end

    selector =
      if options[:has_not] != nil do
        locator = options[:has_not]
        if locator.frame != frame do
          raise ArgumentError, "Inner \"HasNot\" locator must belong to the same frame."
        end

        selector <> " >> internal:has-not=#{JSON.encode!(locator.selector)}"
      else
        selector
      end

    selector =
      if visible != nil do
        selector <> " >> visible=" <> if(visible == true, do: "true", else: "false")
      else
        selector
      end

    %__MODULE__{frame: frame, selector: selector}
  end

  # upstream: Core/Locator.cs:111
  def first(this), do: new(this.frame, "#{this.selector} >> nth=0")

  # upstream: Core/Locator.cs:113
  def last(this), do: new(this.frame, "#{this.selector} >> nth=-1")

  # upstream: Core/Locator.cs:117
  def page(this), do: Frame.page(this.frame)

  # upstream: Core/Locator.cs:160
  def check_async(this, options \\ nil),
    do: Frame.check_async(
      this.frame,
      this.selector,
      convert_options(options))

  # upstream: Core/Locator.cs:165
  def click_async(this, options \\ nil),
    do: Frame.click_internal_async(
      this.frame,
      this.selector,
      convert_options(options),
      options[:steps])

  # upstream: Core/Locator.cs:201
  def fill_async(this, value, options \\ nil),
    do: Frame.fill_async(this.frame, this.selector, value, convert_options(options))

  # upstream: Core/Locator.cs:258
  def nth(this, index), do: new(this.frame, "#{this.selector} >> nth=#{index}")

  # upstream: Core/Locator.cs:336 + :339 + :342 + :345 + :348 + :351
  def select_option_async(this, values, options \\ nil),
    do: Frame.select_option_async(this.frame, this.selector, values, convert_options(options))

  # upstream: Core/Locator.cs:362 + :365 + :368 + :371
  def set_input_files_async(this, files, options \\ nil),
    do: Frame.set_input_files_async(this.frame, this.selector, files, convert_options(options))

  # upstream: Core/Locator.cs:423
  def expect_async(this, expression, options, title),
    do: Playwright.Transport.ChannelOwner.wrap_api_call(
      this.frame,
      fn -> Frame.expect_async(this.frame, this.selector, expression, options) end,
      false,
      title)

  # upstream: Core/Locator.cs:448 (reflection-based property copy -> keyword list; Strict defaults to true)
  defp convert_options(source) do
    Keyword.put_new(source || [], :strict, true)
  end

  # upstream: Core/Locator.cs:526 + :529
  def get_by_label(this, text, options \\ nil),
    do: locator(this, get_by_label_selector(text, options[:exact]))

  # upstream: Core/Locator.cs:538
  def get_by_role(this, role, options \\ nil),
    do: locator(this, get_by_role_selector(role, options || []))

  # upstream: Core/Locator.cs:541 + :544
  def get_by_test_id(this, test_id),
    do: locator(this, get_by_test_id_selector(test_id_attribute_name(), test_id))

  # upstream: Core/Locator.cs:215
  def locator(this, selector, options \\ nil), do: new(this.frame, "#{this.selector} >> #{selector}", options)

  # upstream: Core/Locator.cs:559
  def test_id_attribute_name, do: @test_id_attribute_name

  # upstream: Core/Locator.cs:564 + :567
  def get_by_test_id_selector(test_id_attribute_name, test_id),
    do: "internal:testid=[#{encode_test_id_attribute_name(test_id_attribute_name)}=#{escape_for_attribute_selector(test_id, true)}]"

  # Multiple test id attribute names can be joined with a comma. Attribute names cannot contain commas.
  # upstream: Core/Locator.cs:571
  defp encode_test_id_attribute_name(test_id_attribute_name),
    do: if(String.contains?(test_id_attribute_name, ","), do: JSON.encode!(test_id_attribute_name), else: test_id_attribute_name)

  # upstream: Core/Locator.cs:574 + :577
  def get_by_attribute_text_selector(attr_name, text, exact),
    do: "internal:attr=[#{attr_name}=#{escape_for_attribute_selector(text, exact || false)}]"

  # upstream: Core/Locator.cs:580 + :583
  def get_by_label_selector(text, exact),
    do: "internal:label=" <> escape_for_text_selector(text, exact)

  # upstream: Core/Locator.cs:604 + :607
  def get_by_text_selector(text, exact),
    do: "internal:text=#{escape_for_text_selector(text, exact)}"

  # upstream: Core/Locator.cs:610
  def get_by_role_selector(role, options) do
    props = []
    props = if options[:checked] != nil, do: props ++ [["checked", JSON.encode!(options[:checked])]], else: props
    props = if options[:disabled] != nil, do: props ++ [["disabled", JSON.encode!(options[:disabled])]], else: props
    props = if options[:selected] != nil, do: props ++ [["selected", JSON.encode!(options[:selected])]], else: props
    props = if options[:expanded] != nil, do: props ++ [["expanded", JSON.encode!(options[:expanded])]], else: props
    props = if options[:include_hidden] != nil, do: props ++ [["include-hidden", JSON.encode!(options[:include_hidden])]], else: props
    props = if options[:level] != nil, do: props ++ [["level", Integer.to_string(options[:level])]], else: props
    props = if options[:name] != nil, do: props ++ [["name", escape_for_attribute_selector(options[:name], options[:exact] || false)]], else: props
    props = if options[:pressed] != nil, do: props ++ [["pressed", JSON.encode!(options[:pressed])]], else: props
    "internal:role=#{role}#{Enum.map_join(props, fn [k, v] -> "[#{k}=#{v}]" end)}"
  end

  # upstream: Core/Locator.cs:656 + :666
  defp escape_for_attribute_selector(%Regex{} = value, _exact), do: escape_regex_for_selector(value)

  defp escape_for_attribute_selector(value, exact) do
    # TODO: this should actually be
    #   cssEscape(value).replace(/\\ /g, ' ')
    # However, our attribute selectors do not conform to CSS parsing spec,
    # so we escape them differently.
    exact_flag = if exact, do: "", else: "i"
    "\"#{value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")}\"#{exact_flag}"
  end

  # upstream: Core/Locator.cs:671
  defp escape_regex_for_selector(text) do
    {source, flags} = RegexOptionsExtensions.get_source_and_flags(text)
    # Even number of backslashes followed by the quote -> insert a backslash.
    Regex.replace(~r/(^|[^\\])(\\\\)*(["'`])/, "/#{source}/#{flags}", "\\1\\2\\\\\\3") |> String.replace(">>", "\\>\\>")
  end

  # upstream: Core/Locator.cs:678 + :683
  defp escape_for_text_selector(%Regex{} = text, _exact), do: escape_regex_for_selector(text)

  defp escape_for_text_selector(text, exact) do
    JSON.encode!(text) <> if(exact == true, do: "s", else: "i")
  end
end
