defmodule PlaywrightEx.Runtime.Facade do
  @moduledoc """
  Runtime support (not ported from upstream) for the facade that `mix playwright_ex.gen.api`
  generates from `api.json` (`PlaywrightEx.Browser`, ...).

  The facade converts Elixir arguments to the shapes the ported client expects, then runs the
  call in `PlaywrightEx.Runtime.Api.call/3`:

    * Options: a keyword list or map with snake_case keys (`executable_path:`) becomes a map
      with the JS names (`executablePath`). Unknown keys raise `ArgumentError`, as there are
      no options beyond the official ones.
    * Nested objects (option values, positional arguments) are JS values, as in the Python
      client: maps with the JS keys (`%{sameSite: "Lax"}`), passed as they are, so values
      returned by the client round-trip. Only their keys are checked.
    * Enums of options and positional arguments: atoms (`:no_preference`) become the wire
      strings (`"no-preference"`); strings pass through.
    * `timeout: :infinity` is `timeout: 0` (no timeout, as in JS), likewise a positional
      `timeout` (`set_default_timeout(context, :infinity)`).

  A type is `nil` (passed through), `:timeout` (a positional timeout), `{:object, %{key => {js_key, type}}}`
  (options), `{:fields, %{js_key => type}}` (a nested object), `{:array, type}`, `{:enum, %{atom => string}}`
  or `{:union, [type]}`.
  """
  alias PlaywrightEx.Runtime.Api

  @doc "Runs an async call: `{:ok, value}`, or `{:error, exception}` for anything it raises."
  def async(api_name, receiver, fun) do
    {:ok, Api.call(api_name, receiver, fun)}
  rescue
    e -> {:error, e}
  end

  @doc "Runs an async call and returns its value, raising on error."
  def async!(api_name, receiver, fun), do: Api.call(api_name, receiver, fun)

  @doc "Runs an async call that returns `void` in JS: `:ok`, or `{:error, exception}`."
  def async_void(api_name, receiver, fun) do
    with {:ok, _} <- async(api_name, receiver, fun), do: :ok
  end

  @doc "Runs an async call that returns `void` in JS: `:ok`, raising on error."
  def async_void!(api_name, receiver, fun) do
    async!(api_name, receiver, fun)
    :ok
  end

  @doc "Converts `options` (keyword list or map) of type `{:object, schema}` for the call `api_name`."
  def options!(options, {:object, schema}, api_name), do: object!(options, schema, api_name, [])

  @doc "Converts a positional argument of `type`."
  def arg!(value, type, api_name), do: convert!(value, type, api_name, [])

  @doc "The JS event name for `event` (atom, or the JS name as a string) in `events`."
  def event!(event, events, api_name) do
    cond do
      is_atom(event) and Map.has_key?(events, event) -> Map.fetch!(events, event)
      is_binary(event) and event in Map.values(events) -> event
      true -> raise ArgumentError, "#{api_name}: unknown event #{inspect(event)}, expected one of #{keys(events)}"
    end
  end

  defp convert!(nil, _type, _api_name, _path), do: nil
  defp convert!(value, nil, _api_name, _path), do: value
  defp convert!(value, :timeout, _api_name, _path), do: timeout(:timeout, value)

  defp convert!(value, {:fields, fields}, api_name, path) do
    if object?(value), do: fields!(value, fields, api_name, path)
    value
  end

  defp convert!(value, {:array, type}, api_name, path) when is_list(value),
    do: Enum.map(value, &convert!(&1, type, api_name, path))

  defp convert!(value, {:enum, literals}, api_name, path) when is_atom(value) and value not in [:null, true, false] do
    case literals do
      %{^value => literal} ->
        literal

      _ ->
        raise ArgumentError,
              "#{api_name}: invalid value #{inspect(value)} for #{name(path)}, expected one of #{keys(literals)}"
    end
  end

  defp convert!(value, {:union, types}, api_name, path) do
    type =
      cond do
        object?(value) -> Enum.find(types, &match?({:fields, _}, &1))
        is_list(value) -> Enum.find(types, &match?({:array, _}, &1))
        is_atom(value) -> Enum.find(types, &match?({:enum, _}, &1))
        true -> nil
      end

    convert!(value, type, api_name, path)
  end

  defp convert!(value, _type, _api_name, _path), do: value

  defp object!(value, schema, api_name, path) do
    Map.new(value, fn {key, value} ->
      case Map.get(schema, key) do
        {js_key, type} ->
          {js_key, timeout(js_key, convert!(value, type, api_name, [key | path]))}

        nil ->
          raise ArgumentError,
                "#{api_name}: unknown option #{name([key | path])}, expected one of #{keys(schema)}"
      end
    end)
  end

  defp fields!(value, fields, api_name, path) do
    for {key, value} <- value do
      case fields do
        %{^key => type} -> convert!(value, type, api_name, [key | path])
        _ -> raise ArgumentError, "#{api_name}: unknown field #{name([key | path])}, expected one of #{keys(fields)}"
      end
    end
  end

  defp timeout(:timeout, :infinity), do: 0
  defp timeout(_key, value), do: value

  defp object?(value), do: is_map(value) and not is_struct(value)

  # [:server, :proxy] is ":proxy.server"; [] is a positional argument.
  defp name([]), do: "argument"
  defp name(path), do: path |> Enum.reverse() |> then(fn [key | rest] -> Enum.join([inspect(key) | rest], ".") end)

  defp keys(map), do: map |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &inspect/1)
end
