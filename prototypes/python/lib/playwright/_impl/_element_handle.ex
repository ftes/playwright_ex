# upstream: playwright/_impl/_element_handle.py (subset: module-level helpers only)
defmodule Playwright.Impl.ElementHandle do
  # upstream: _element_handle.py:437
  def convert_select_option_values(value \\ nil, index \\ nil, label \\ nil, element \\ nil) do
    if value == nil and index == nil and label == nil and element == nil do
      []
    else
      options = nil
      elements = nil

      options =
        if value != nil do
          value = if is_binary(value), do: [value], else: value
          List.wrap(options) ++ Enum.map(value, fn e -> %{"valueOrLabel" => e} end)
        else
          options
        end

      options =
        if index != nil do
          index = if is_integer(index), do: [index], else: index
          List.wrap(options) ++ Enum.map(index, fn e -> %{"index" => e} end)
        else
          options
        end

      options =
        if label != nil do
          label = if is_binary(label), do: [label], else: label
          List.wrap(options) ++ Enum.map(label, fn e -> %{"label" => e} end)
        else
          options
        end

      elements =
        if element do
          element = if is_list(element), do: element, else: [element]
          Enum.map(element, fn e -> e[:_channel] end)
        else
          elements
        end

      [options: options, elements: elements]
    end
  end
end
