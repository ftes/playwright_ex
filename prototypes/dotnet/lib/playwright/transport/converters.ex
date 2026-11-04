defmodule Playwright.Transport.Converters do
  @moduledoc """
  Stand-in for `Transport/Converters/*` and `Helpers/JsonExtensions.cs` (System.Text.Json converters).

  Wire format stays camelCase string-keyed maps (like `JsonElement`); only channel-owner references
  (`{"guid": ...}`) and generated protocol structs are converted.
  """

  alias Playwright.Transport.Connection

  # upstream: Transport/Converters/ChannelOwnerConverterFactory.cs (Read)
  def to_channel_owner(nil, _connection), do: nil
  def to_channel_owner(%{"guid" => guid}, connection), do: Connection.get_object(connection, guid)

  # Enums (WaitUntilState, LoadState, AriaRole, ...) are atoms named after their wire value.
  def to_enum(nil), do: nil
  def to_enum(value) when is_binary(value), do: String.to_atom(value)

  def map_list(nil, _fun), do: nil
  def map_list(list, fun), do: Enum.map(list, fun)

  def drop_nils(map), do: map |> Enum.reject(fn {_, v} -> is_nil(v) end) |> Map.new()

  @doc "Serializer pass (DefaultJsonSerializerOptions): channel owners -> {guid}, structs -> to_json, nils dropped."
  def to_protocol(value, keep_nulls \\ false)
  def to_protocol(%{__channel_owner__: true, guid: guid}, _), do: %{"guid" => guid}
  def to_protocol(%Regex{} = re, _), do: Regex.source(re)
  def to_protocol(atom, _) when is_atom(atom) and atom not in [nil, true, false], do: Atom.to_string(atom)

  def to_protocol(%mod{} = struct, keep_nulls) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :to_json, 1),
      do: to_protocol(mod.to_json(struct), keep_nulls),
      else: struct |> Map.from_struct() |> to_protocol(keep_nulls)
  end

  def to_protocol(map, keep_nulls) when is_map(map) do
    for {k, v} <- map, keep_nulls or not is_nil(v), into: %{}, do: {to_string(k), to_protocol(v, keep_nulls)}
  end

  def to_protocol(list, keep_nulls) when is_list(list), do: Enum.map(list, &to_protocol(&1, keep_nulls))
  def to_protocol(value, _), do: value
end
