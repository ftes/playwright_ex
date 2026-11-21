defmodule Playwright.Runtime.ProtocolType do
  @moduledoc false
  # Runtime support (not ported from upstream): the facade type (`Playwright.Runtime.Facade`) of
  # a value the client passes on to the protocol. The generated facade computes it when it
  # compiles, so this module depends on the protocol's schemes only: the facade modules don't
  # recompile when `Facade` or what it calls changes.

  alias Playwright.Protocol.Validator

  @doc """
  The type of `field` of the protocol's `params` (`Playwright.Protocol.Validator`): a value the
  client passes on (cookies, storage states), whose objects take the protocol's keys as atoms or
  strings. The values of the `unchecked` keys, at any depth, pass as they are: those the
  protocol's validator drops unread (`APIRequest.newContext`'s storage state `credentials`). So
  does a type nested in itself (`SerializedValue`), at the depth it recurs.
  """
  def of(params, field, unchecked \\ []) do
    {:object, fields} = Validator.scheme(params)
    type(Keyword.fetch!(fields, field), unchecked, [])
  end

  defp type({:optional, scheme}, unchecked, seen), do: type(scheme, unchecked, seen)

  defp type({:type, name}, unchecked, seen) do
    if name not in seen, do: type(Validator.scheme(name), unchecked, [name | seen])
  end

  defp type({:array, scheme}, unchecked, seen) do
    if type = type(scheme, unchecked, seen), do: {:array, type}
  end

  defp type({:object, fields}, unchecked, seen) do
    atoms =
      Map.new(fields, fn {key, scheme} -> {key, if(key not in unchecked, do: type(scheme, unchecked, seen))} end)

    {:protocol, atoms, Map.new(atoms, fn {key, type} -> {Atom.to_string(key), type} end)}
  end

  defp type(_scheme, _unchecked, _seen), do: nil
end
