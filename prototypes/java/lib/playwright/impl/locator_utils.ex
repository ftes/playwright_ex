defmodule Playwright.Impl.LocatorUtils do
  # upstream: LocatorUtils.java:27
  alias Playwright.Impl.{Heap, Utils}

  # upstream: LocatorUtils.java:28
  def get_by_text_selector(text, options) do
    exact = options != nil and options.exact != nil and options.exact
    "internal:text=" <> escape_for_text_selector(text, exact)
  end

  # upstream: LocatorUtils.java:33
  def get_by_label_selector(text, options) do
    exact = options != nil and options.exact != nil and options.exact
    "internal:label=" <> escape_for_text_selector(text, exact)
  end

  # upstream: LocatorUtils.java:38
  defp get_by_attribute_text_selector(attr_name, value, exact) do
    "internal:attr=[" <> attr_name <> "=" <> escape_for_attribute_selector(value, exact) <> "]"
  end

  # upstream: LocatorUtils.java:42
  def describe_selector(description), do: "internal:describe=" <> JSON.encode!(description)

  # upstream: LocatorUtils.java:47
  # Multiple test id attribute names can be joined with a comma. Attribute names cannot contain commas.
  defp encode_test_id_attribute_name(test_id_attribute_name) do
    if String.contains?(test_id_attribute_name, ","),
      do: JSON.encode!(test_id_attribute_name),
      else: test_id_attribute_name
  end

  # upstream: LocatorUtils.java:51
  def get_by_test_id_selector(test_id, playwright) do
    attribute_name = encode_test_id_attribute_name(Heap.get(playwright, :selectors).test_id_attribute_name)
    "internal:testid=[" <> attribute_name <> "=" <> escape_for_attribute_selector(test_id, true) <> "]"
  end

  # upstream: LocatorUtils.java:56
  def get_by_alt_text_selector(text, options) do
    exact = options != nil and options.exact != nil and options.exact
    get_by_attribute_text_selector("alt", text, exact)
  end

  # upstream: LocatorUtils.java:61
  def get_by_title_selector(text, options) do
    exact = options != nil and options.exact != nil and options.exact
    get_by_attribute_text_selector("title", text, exact)
  end

  # upstream: LocatorUtils.java:66
  def get_by_placeholder_selector(text, options) do
    exact = options != nil and options.exact != nil and options.exact
    get_by_attribute_text_selector("placeholder", text, exact)
  end

  # upstream: LocatorUtils.java:71
  defp add_attr(result, name, value), do: result <> "[" <> name <> "=" <> value <> "]"

  # upstream: LocatorUtils.java:75
  # Java appends to a StringBuilder; Elixir rebinds `result` after each append.
  def get_by_role_selector(role, options) do
    result = "internal:role=" <> String.downcase(to_string(role))

    if options != nil do
      result = if options.checked != nil, do: add_attr(result, "checked", to_string(options.checked)), else: result
      result = if options.disabled != nil, do: add_attr(result, "disabled", to_string(options.disabled)), else: result
      result = if options.selected != nil, do: add_attr(result, "selected", to_string(options.selected)), else: result
      result = if options.expanded != nil, do: add_attr(result, "expanded", to_string(options.expanded)), else: result

      result =
        if options.include_hidden != nil,
          do: add_attr(result, "include-hidden", to_string(options.include_hidden)),
          else: result

      result = if options.level != nil, do: add_attr(result, "level", to_string(options.level)), else: result

      result =
        if options.name != nil do
          name = escape_for_attribute_selector(options.name, options.exact != nil and options.exact)
          add_attr(result, "name", name)
        else
          result
        end

      result =
        if options.description != nil do
          description = escape_for_attribute_selector(options.description, options.exact != nil and options.exact)
          add_attr(result, "description", description)
        else
          result
        end

      if options.pressed != nil, do: add_attr(result, "pressed", to_string(options.pressed)), else: result
    else
      result
    end
  end

  # upstream: LocatorUtils.java:105
  defp escape_regex_for_selector(re) do
    # Even number of backslashes followed by the quote -> insert a backslash.
    to_js_reg_exp(re)
    |> String.replace(~r/(^|[^\\])(\\\\)*(["'`])/, "\\1\\2\\\\\\3")
    |> String.replace(">>", "\\>\\>")
  end

  # upstream: LocatorUtils.java:110
  def escape_for_text_selector(%Regex{} = value, _exact), do: escape_regex_for_selector(value)

  def escape_for_text_selector(value, exact) when is_binary(value),
    do: JSON.encode!(value) <> if(exact, do: "s", else: "i")

  def escape_for_text_selector(value, _exact),
    do: raise(ArgumentError, "text parameter must be Pattern or String: #{inspect(value)}")

  # upstream: LocatorUtils.java:120
  defp escape_for_attribute_selector(%Regex{} = value, _exact), do: escape_regex_for_selector(value)

  defp escape_for_attribute_selector(value, exact) when is_binary(value) do
    # TODO: this should actually be
    #   cssEscape(value).replace(/\\ /g, ' ')
    # However, our attribute selectors do not conform to CSS parsing spec,
    # so we escape them differently.
    "\"" <>
      (value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")) <> "\"" <> if(exact, do: "", else: "i")
  end

  defp escape_for_attribute_selector(value, _exact),
    do: raise(ArgumentError, "Attribute can be String or Pattern, found: #{inspect(value)}")

  # upstream: LocatorUtils.java:134
  defp to_js_reg_exp(pattern), do: "/" <> Regex.source(pattern) <> "/" <> Utils.to_js_regex_flags(pattern)
end
