defmodule PlaywrightEx.RouteMatcher do
  @moduledoc false

  def compile(%Regex{} = regex), do: regex
  def compile(glob) when is_binary(glob), do: Regex.compile!("\\A" <> glob(glob, nil, false) <> "\\z", "s")

  defp glob("", _, false), do: ""
  defp glob("", _, true), do: raise(ArgumentError, "unclosed glob group")
  defp glob("\\" <> <<char::utf8, rest::binary>>, _, group), do: Regex.escape(<<char::utf8>>) <> glob(rest, char, group)

  defp glob("*" <> rest, previous, group) do
    stars = String.length(rest) - String.length(String.trim_leading(rest, "*"))
    rest = String.trim_leading(rest, "*")

    case {stars, rest, previous} do
      {0, _, _} -> "[^/]*" <> glob(rest, ?*, group)
      {_, "/" <> tail, ?/} -> "(?:(?:.+/)|)" <> glob(tail, ?/, group)
      {_, "/" <> tail, _} -> ".*/" <> glob(tail, ?/, group)
      _ -> ".*" <> glob(rest, ?*, group)
    end
  end

  defp glob("{" <> rest, _, false), do: "(?:" <> glob(rest, ?{, true)
  defp glob("{" <> _, _, true), do: raise(ArgumentError, "nested glob groups are unsupported")
  defp glob("}" <> rest, _, true), do: ")" <> glob(rest, ?}, false)
  defp glob("}" <> _, _, false), do: raise(ArgumentError, "unmatched glob closing brace")
  defp glob("," <> rest, _, true), do: "|" <> glob(rest, ?,, true)
  defp glob(<<char::utf8, rest::binary>>, _, group), do: Regex.escape(<<char::utf8>>) <> glob(rest, char, group)
end
