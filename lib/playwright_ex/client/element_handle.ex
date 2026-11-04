defmodule PlaywrightEx.Client.ElementHandle do
  @upstream "packages/playwright-core/src/client/elementHandle.ts"
  @moduledoc "Port of `#{@upstream}`: only the module functions Frame needs so far."

  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Runtime.Heap

  # class ElementHandle  -- not ported: ElementHandle (a DummyChannelOwner for now)

  def convert_select_option_values(values) do
    values = if is_list(values) or values == nil, do: values, else: [values]

    cond do
      values == nil ->
        %{}

      values == [] ->
        %{}

      true ->
        for {value, i} <- Enum.with_index(values),
            value == nil,
            do: raise("options[#{i}]: expected object, got null")

        cond do
          is_element_handle(hd(values)) -> %{elements: values}
          is_binary(hd(values)) -> %{options: Enum.map(values, &%{valueOrLabel: &1})}
          true -> %{options: values}
        end
    end
  end

  # filePayloadExceedsSizeLimit, resolvePathsAndDirectoryForInputFiles, convertInputFiles  -- not ported: convertInputFiles
  # determineScreenshotType  -- not ported: screenshot

  # `value instanceof ElementHandle`
  defp is_element_handle(value),
    do: ChannelOwner.is_channel_owner(value) and Heap.get(value, :_type) == "ElementHandle"
end
