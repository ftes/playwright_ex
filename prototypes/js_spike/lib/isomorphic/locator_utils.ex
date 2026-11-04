# upstream: packages/isomorphic/locatorUtils.ts
defmodule PlaywrightJS.Isomorphic.LocatorUtils do
  import PlaywrightJS.Isomorphic.StringUtils, only: [escape_for_attribute_selector: 2, escape_for_text_selector: 2]

  # upstream: locatorUtils.ts:32
  defp get_by_attribute_text_selector(attr_name, text, options) do
    "internal:attr=[#{attr_name}=#{escape_for_attribute_selector(text, (options || %{})[:exact] || false)}]"
  end

  # upstream: locatorUtils.ts:37
  def split_test_id_attribute_names(test_id_attribute_name) do
    String.split(test_id_attribute_name, ",")
  end

  # upstream: locatorUtils.ts:41
  def encode_test_id_attribute_name(test_id_attribute_name) do
    if String.contains?(test_id_attribute_name, ","), do: JSON.encode!(test_id_attribute_name), else: test_id_attribute_name
  end

  # upstream: locatorUtils.ts:45
  def get_by_test_id_selector(test_id_attribute_name, test_id) do
    "internal:testid=[#{encode_test_id_attribute_name(test_id_attribute_name)}=#{escape_for_attribute_selector(test_id, true)}]"
  end

  # upstream: locatorUtils.ts:49
  def get_by_label_selector(text, options \\ nil) do
    "internal:label=" <> escape_for_text_selector(text, !!(options || %{})[:exact])
  end

  # upstream: locatorUtils.ts:53
  def get_by_alt_text_selector(text, options \\ nil) do
    get_by_attribute_text_selector("alt", text, options)
  end

  # upstream: locatorUtils.ts:57
  def get_by_title_selector(text, options \\ nil) do
    get_by_attribute_text_selector("title", text, options)
  end

  # upstream: locatorUtils.ts:61
  def get_by_placeholder_selector(text, options \\ nil) do
    get_by_attribute_text_selector("placeholder", text, options)
  end

  # upstream: locatorUtils.ts:65
  def get_by_text_selector(text, options \\ nil) do
    "internal:text=" <> escape_for_text_selector(text, !!(options || %{})[:exact])
  end

  # upstream: locatorUtils.ts:69
  def get_by_role_selector(role, options \\ %{}) do
    props = []
    props = if options[:checked] != nil, do: props ++ [["checked", to_string(options.checked)]], else: props
    props = if options[:disabled] != nil, do: props ++ [["disabled", to_string(options.disabled)]], else: props
    props = if options[:selected] != nil, do: props ++ [["selected", to_string(options.selected)]], else: props
    props = if options[:expanded] != nil, do: props ++ [["expanded", to_string(options.expanded)]], else: props
    props = if options[:includeHidden] != nil, do: props ++ [["include-hidden", to_string(options.includeHidden)]], else: props
    props = if options[:level] != nil, do: props ++ [["level", to_string(options.level)]], else: props
    props = if options[:name] != nil, do: props ++ [["name", escape_for_attribute_selector(options.name, !!options[:exact])]], else: props

    props =
      if options[:description] != nil,
        do: props ++ [["description", escape_for_attribute_selector(options.description, !!options[:exact])]],
        else: props

    props = if options[:pressed] != nil, do: props ++ [["pressed", to_string(options.pressed)]], else: props
    "internal:role=#{role}#{Enum.map_join(props, fn [n, v] -> "[#{n}=#{v}]" end)}"
  end
end
