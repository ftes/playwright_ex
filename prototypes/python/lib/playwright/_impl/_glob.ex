# upstream: playwright/_impl/_glob.py
defmodule Playwright.Impl.Glob do
  @escaped_chars ~w($ ^ + . * \( \) | \\ ? { } [ ])

  # upstream: _glob.py:19
  def glob_to_regex_pattern(glob) do
    chars = String.graphemes(glob)
    tokens = ["^"]
    {tokens, _in_group} = loop(chars, 0, tokens, false)
    tokens = tokens ++ ["$"]
    Enum.join(tokens)
  end

  # while i < len(glob): ... (index-mutating while loop -> recursion)
  defp loop(glob, i, tokens, in_group) when i >= length(glob), do: {tokens, in_group}

  defp loop(glob, i, tokens, in_group) do
    c = Enum.at(glob, i)

    {tokens, in_group, i} =
      cond do
        c == "\\" and i + 1 < length(glob) ->
          char = Enum.at(glob, i + 1)
          {tokens ++ [if(char in @escaped_chars, do: "\\" <> char, else: char)], in_group, i + 1}

        c == "*" ->
          char_before = if i > 0, do: Enum.at(glob, i - 1)
          {star_count, i} = count_stars(glob, i, 1)

          if star_count > 1 do
            char_after = if i + 1 < length(glob), do: Enum.at(glob, i + 1)

            if char_after == "/" do
              {tokens ++ [if(char_before == "/", do: "((.+/)|)", else: "(.*/)")], in_group, i + 1}
            else
              {tokens ++ ["(.*)"], in_group, i}
            end
          else
            {tokens ++ ["([^/]*)"], in_group, i}
          end

        c == "{" ->
          {tokens ++ ["("], true, i}

        c == "}" ->
          {tokens ++ [")"], false, i}

        c == "," ->
          {tokens ++ [if(in_group, do: "|", else: "\\" <> c)], in_group, i}

        true ->
          {tokens ++ [if(c in @escaped_chars, do: "\\" <> c, else: c)], in_group, i}
      end

    loop(glob, i + 1, tokens, in_group)
  end

  defp count_stars(glob, i, n) do
    if i + 1 < length(glob) and Enum.at(glob, i + 1) == "*",
      do: count_stars(glob, i + 1, n + 1),
      else: {n, i}
  end
end
