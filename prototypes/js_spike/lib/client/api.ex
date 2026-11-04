defmodule PlaywrightJS.Client.Api do
  @moduledoc """
  Runtime support (not ported from upstream).

  Upstream derives `apiName` ("page.waitForEvent") from the JS stack in
  `captureLibraryStackTrace`. BEAM stack traces drop tail-call frames, so the public
  entry point is often missing. `use PlaywrightJS.Client.Api` replaces `def` so that every
  public, non-underscore function records its JS API name before running its body;
  the source keeps reading as plain `def`.

  The same hook opens the baton scope (`Baton.api_scope/2`): the outermost public call
  takes the baton (from its receiver) and keeps it until it returns, except while awaiting.
  """

  @skip [:new, :from, :from_nullable, :__channel_owner__, :is_channel_owner, :channel_call]

  defmacro __using__(opts) do
    quote do
      @pw_api_name Keyword.get(unquote(opts), :api_name, true)
      import Kernel, except: [def: 2]
      import PlaywrightJS.Client.Api, only: [def: 2]
    end
  end

  defmacro def(head, body) do
    name = head |> strip_guard() |> elem(0)

    if name in @skip or String.starts_with?(Atom.to_string(name), "_") or Keyword.keys(body) != [:do] do
      quote do: Kernel.def(unquote(head), unquote(body))
    else
      api_name = api_name(__CALLER__.module, name)

      receiver = receiver(head)

      quote do
        Kernel.def unquote(head) do
          PlaywrightJS.Client.Api.with_api_name(@pw_api_name && unquote(api_name), unquote(receiver), fn -> unquote(body[:do]) end)
        end
      end
    end
  end

  defp receiver(head) do
    case head |> strip_guard() |> elem(2) do
      [{:\\, _, [{name, _, ctx} = var, _]} | _] when is_atom(name) and is_atom(ctx) -> var
      [{name, _, ctx} = var | _] when is_atom(name) and is_atom(ctx) and name != :_ -> var
      _ -> nil
    end
  end

  defp strip_guard({:when, _, [call | _]}), do: call
  defp strip_guard(call), do: call

  defp api_name(module, name) do
    class = module |> Module.split() |> List.last()
    [first | rest] = name |> Atom.to_string() |> String.trim_trailing("_") |> String.split("_")
    String.downcase(String.first(class)) <> String.slice(class, 1..-1//1) <> "." <> first <> Enum.map_join(rest, &String.capitalize/1)
  end

  def with_api_name(api_name, receiver, fun) do
    PlaywrightJS.Runtime.Baton.api_scope(receiver, fn ->
      if !api_name or PlaywrightJS.Runtime.Zones.data(:apiName),
        do: fun.(),
        else: PlaywrightJS.Runtime.Zones.with(:apiName, api_name, fun)
    end)
  end
end
