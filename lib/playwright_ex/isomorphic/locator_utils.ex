defmodule PlaywrightEx.Isomorphic.LocatorUtils do
  @upstream "packages/isomorphic/locatorUtils.ts"
  @moduledoc "Port of `#{@upstream}`. Options are maps with the JS keys (`ByRoleOptions`)."

  import PlaywrightEx.Isomorphic.StringUtils

  defp get_by_attribute_text_selector(attr_name, text, options) do
    "internal:attr=[#{attr_name}=#{escape_for_attribute_selector(text, options[:exact] || false)}]"
  end

  # Multiple test id attribute names can be joined with a comma. Attribute names cannot contain commas.
  def split_test_id_attribute_names(test_id_attribute_name) do
    String.split(test_id_attribute_name, ",")
  end

  def encode_test_id_attribute_name(test_id_attribute_name) do
    if String.contains?(test_id_attribute_name, ","),
      do: JSON.encode!(test_id_attribute_name),
      else: test_id_attribute_name
  end

  def get_by_test_id_selector(test_id_attribute_name, test_id) do
    "internal:testid=[#{encode_test_id_attribute_name(test_id_attribute_name)}=#{escape_for_attribute_selector(test_id, true)}]"
  end

  def get_by_label_selector(text, options \\ nil) do
    "internal:label=" <> escape_for_text_selector(text, !!options[:exact])
  end

  def get_by_alt_text_selector(text, options \\ nil) do
    get_by_attribute_text_selector("alt", text, options)
  end

  def get_by_title_selector(text, options \\ nil) do
    get_by_attribute_text_selector("title", text, options)
  end

  def get_by_placeholder_selector(text, options \\ nil) do
    get_by_attribute_text_selector("placeholder", text, options)
  end

  def get_by_text_selector(text, options \\ nil) do
    "internal:text=" <> escape_for_text_selector(text, !!options[:exact])
  end

  def get_by_role_selector(role, options \\ %{}) do
    props =
      [
        options[:checked] != nil && ["checked", string(options.checked)],
        options[:disabled] != nil && ["disabled", string(options.disabled)],
        options[:selected] != nil && ["selected", string(options.selected)],
        options[:expanded] != nil && ["expanded", string(options.expanded)],
        options[:includeHidden] != nil && ["include-hidden", string(options.includeHidden)],
        options[:level] != nil && ["level", string(options.level)],
        options[:name] != nil && ["name", escape_for_attribute_selector(options.name, !!options[:exact])],
        options[:description] != nil &&
          ["description", escape_for_attribute_selector(options.description, !!options[:exact])],
        options[:pressed] != nil && ["pressed", string(options.pressed)]
      ]
      |> Enum.filter(& &1)

    "internal:role=#{role}#{Enum.map_join(props, fn [n, v] -> "[#{n}=#{v}]" end)}"
  end

  # String(value): booleans, "mixed" and numbers.
  defp string(value), do: to_string(value)
end
