defmodule PlaywrightEx.Isomorphic.SelectorParser do
  @upstream "packages/isomorphic/selectorParser.ts"
  @moduledoc """
  Port of `#{@upstream}`. A `ParsedSelector` is `%{parts: [part], capture: index | nil}`, a part
  `%{name, body, source}`, a nested body `%{parsed, distance}`. CSS parts keep their source as
  the body: `parseCSS` is not ported (`PlaywrightEx.Isomorphic.CssParser`), so invalid CSS is not
  detected here. `RegExp` values are `PlaywrightEx.Isomorphic.RegExp`.
  """

  alias PlaywrightEx.Isomorphic.CssParser.InvalidSelectorError
  alias PlaywrightEx.Isomorphic.RegExp

  @k_nested_selector_names ~w(internal:has internal:has-not internal:and internal:or internal:chain left-of right-of above below near)
  @k_nested_selector_names_with_distance ~w(left-of right-of above below near)

  # customCSSNames  -- not ported: only parseCSS reads it

  def parse_selector(selector) do
    parsed_strings = parse_selector_string(selector)

    parts =
      Enum.reduce(parsed_strings.parts, [], fn part, parts ->
        cond do
          part.name == "css" or part.name == "css:light" ->
            body = if part.name == "css:light", do: ":light(" <> part.body <> ")", else: part.body
            # const parsedCSS = parseCSS(part.body, customCSSNames);  -- not ported: the body stays the CSS source
            parts ++ [%{name: "css", body: body, source: body}]

          part.name in @k_nested_selector_names ->
            {inner_selector, distance} =
              try do
                unescaped = JSON.decode!("[" <> part.body <> "]")

                if !is_list(unescaped) or unescaped == [] or length(unescaped) > 2 or
                     !is_binary(hd(unescaped)),
                   do: raise(InvalidSelectorError, "Malformed selector: #{part.name}=" <> part.body)

                distance =
                  case unescaped do
                    [_, distance] ->
                      if !is_number(distance) or part.name not in @k_nested_selector_names_with_distance,
                        do: raise(InvalidSelectorError, "Malformed selector: #{part.name}=" <> part.body)

                      distance

                    [_] ->
                      nil
                  end

                {hd(unescaped), distance}
              rescue
                _ -> reraise InvalidSelectorError, "Malformed selector: #{part.name}=" <> part.body, __STACKTRACE__
              end

            nested = %{
              name: part.name,
              source: part.body,
              body: %{parsed: parse_selector(inner_selector), distance: distance}
            }

            nested_parts = nested.body.parsed.parts

            last_frame_index =
              nested_parts
              |> Enum.with_index()
              |> Enum.reverse()
              |> Enum.find_value(-1, fn {p, i} -> if p.name == "internal:control" and p.body == "enter-frame", do: i end)

            # The "any-frame" token applies to the whole selector, so nested selectors must not repeat it.
            outer_parts =
              case parts do
                [%{name: "internal:control", body: "any-frame"} | rest] -> rest
                _ -> parts
              end

            # Allow nested selectors to start with the same frame selector.
            nested =
              if last_frame_index != -1 and
                   selector_parts_equal(
                     Enum.take(nested_parts, last_frame_index + 1),
                     Enum.take(outer_parts, last_frame_index + 1)
                   ) do
                parsed = %{nested.body.parsed | parts: Enum.drop(nested_parts, last_frame_index + 1)}

                parsed =
                  if parsed.capture != nil do
                    if parsed.capture <= last_frame_index,
                      do:
                        raise(
                          InvalidSelectorError,
                          "Can not capture the selector before diving into the frame. Only use * after the last frame has been selected"
                        )

                    # The capture refers to a part index, so it shifts along with the removed prefix.
                    %{parsed | capture: parsed.capture - (last_frame_index + 1)}
                  else
                    parsed
                  end

                put_in(nested.body.parsed, parsed)
              else
                nested
              end

            parts ++ [nested]

          true ->
            parts ++ [Map.put(part, :source, part.body)]
        end
      end)

    if hd(parts).name in @k_nested_selector_names,
      do: raise(InvalidSelectorError, ~s("#{hd(parts).name}" selector cannot be first))

    %{capture: parsed_strings.capture, parts: parts}
  end

  # Matches in any frame of the subtree, instead of the frame itself. Only allowed as the first token.
  def k_any_frame_selector, do: "internal:control=any-frame"

  # Splits a selector into per-frame chunks separated by "enter-frame" boundaries.
  # The optional leading "any-frame" token is consumed and reported separately.
  def split_selector_by_frame(selector_text) do
    selector = parse_selector(selector_text)

    state =
      selector.parts
      |> Enum.with_index()
      |> Enum.reduce(%{chunks: [], chunk: %{parts: [], capture: nil}, anyFrame: false, chunkStartIndex: 0}, fn
        {%{name: "internal:control", body: "any-frame"} = part, i}, state ->
          # The starting frame applies to the whole selector, so the token only makes sense as the very first one.
          if i != 0,
            do:
              raise(
                InvalidSelectorError,
                ~s("#{part.body}" is only allowed as the first selector token, while parsing selector #{selector_text})
              )

          %{state | anyFrame: true, chunkStartIndex: i + 1}

        {%{name: "internal:control", body: "enter-frame"}, i}, state ->
          last_part = List.last(state.chunk.parts)

          if !last_part or (last_part.name == "internal:control" and last_part.body == "enter-frame"),
            do: raise(InvalidSelectorError, "Selector cannot start with entering frame, select the iframe first")

          %{state | chunks: state.chunks ++ [state.chunk], chunk: %{parts: [], capture: nil}, chunkStartIndex: i + 1}

        {part, i}, state ->
          chunk = if selector.capture == i, do: %{state.chunk | capture: i - state.chunkStartIndex}, else: state.chunk
          %{state | chunk: %{chunk | parts: chunk.parts ++ [part]}}
      end)

    %{chunks: chunks, chunk: chunk, anyFrame: any_frame} = state

    if chunk.parts == [] do
      if any_frame and chunks == [],
        do:
          raise(
            InvalidSelectorError,
            "Selector cannot be empty after frameLocator(), while parsing selector #{selector_text}"
          )

      raise InvalidSelectorError, "Selector cannot end with entering frame, while parsing selector #{selector_text}"
    end

    last_part = List.last(chunk.parts)

    if last_part.name == "internal:control" and last_part.body == "enter-frame",
      do:
        raise(InvalidSelectorError, "Selector cannot end with entering frame, while parsing selector #{selector_text}")

    chunks = chunks ++ [chunk]

    if is_integer(selector.capture) and !is_integer(List.last(chunks).capture),
      do:
        raise(
          InvalidSelectorError,
          "Can not capture the selector before diving into the frame. Only use * after the last frame has been selected"
        )

    %{anyFrame: any_frame, chunks: chunks}
  end

  defp selector_parts_equal(list1, list2) do
    stringify_selector(%{parts: list1}) == stringify_selector(%{parts: list2})
  end

  def stringify_selector(selector, force_engine_name \\ false)

  def stringify_selector(selector, _force_engine_name) when is_binary(selector), do: selector

  def stringify_selector(selector, force_engine_name) do
    capture = selector[:capture]

    selector.parts
    |> Enum.with_index()
    |> Enum.map_join(" >> ", fn {p, i} ->
      include_engine =
        cond do
          force_engine_name or i == capture -> true
          p.name == "css" -> false
          p.name == "xpath" and (String.starts_with?(p.source, "//") or String.starts_with?(p.source, "..")) -> false
          true -> true
        end

      prefix = if include_engine, do: p.name <> "=", else: ""
      "#{if i == capture, do: "*", else: ""}#{prefix}#{p.source}"
    end)
  end

  # The visitor folds an accumulator (`visitor.(part, nested, acc)`) instead of closing over mutable state.
  def visit_all_selector_parts(selector, acc, visitor) do
    visit(selector, false, acc, visitor)
  end

  defp visit(selector, nested, acc, visitor) do
    Enum.reduce(selector.parts, acc, fn part, acc ->
      acc = visitor.(part, nested, acc)
      if part.name in @k_nested_selector_names, do: visit(part.body.parsed, true, acc, visitor), else: acc
    end)
  end

  # Scans bytes: every character it looks at (quotes, `\`, `>>`) is ASCII.
  defp parse_selector_string(selector) do
    result = %{parts: [], capture: nil}

    if not String.contains?(selector, ">>"),
      do: append(selector, 0, byte_size(selector), result),
      else: scan(selector, 0, nil, 0, result)
  end

  defp scan(selector, index, quote, start, result) when index < byte_size(selector) do
    c = :binary.at(selector, index)

    cond do
      c == ?\\ and index + 1 < byte_size(selector) ->
        scan(selector, index + 2, quote, start, result)

      c == quote ->
        scan(selector, index + 1, nil, start, result)

      !quote and c in [?", ?', ?`] and !should_ignore_text_selector_quote(selector, start, index) ->
        scan(selector, index + 1, c, start, result)

      !quote and c == ?> and index + 1 < byte_size(selector) and :binary.at(selector, index + 1) == ?> ->
        result = append(selector, start, index, result)
        scan(selector, index + 2, quote, index + 2, result)

      true ->
        scan(selector, index + 1, quote, start, result)
    end
  end

  defp scan(selector, index, _quote, start, result), do: append(selector, start, index, result)

  defp append(selector, start, index, result) do
    index = min(index, byte_size(selector))
    part = selector |> binary_part(start, max(index - start, 0)) |> String.trim()

    eq_index =
      case :binary.match(part, "=") do
        {i, _} -> i
        :nomatch -> -1
      end

    {name, body} =
      cond do
        eq_index != -1 and Regex.match?(~r/\A[a-zA-Z_0-9\-+:*]+\z/, String.trim(binary_part(part, 0, eq_index))) ->
          {String.trim(binary_part(part, 0, eq_index)), binary_part(part, eq_index + 1, byte_size(part) - eq_index - 1)}

        byte_size(part) > 1 and String.starts_with?(part, "\"") and String.ends_with?(part, "\"") ->
          {"text", part}

        byte_size(part) > 1 and String.starts_with?(part, "'") and String.ends_with?(part, "'") ->
          {"text", part}

        # If selector starts with '//' or '//' prefixed with multiple opening
        # parenthesis, consider xpath. @see https://github.com/microsoft/playwright/issues/817
        # If selector starts with '..', consider xpath as well.
        Regex.match?(~r/\A\(*\/\//, part) or String.starts_with?(part, "..") ->
          {"xpath", part}

        true ->
          {"css", part}
      end

    {capture, name} =
      case name do
        "*" <> rest -> {true, rest}
        _ -> {false, name}
      end

    parts = result.parts ++ [%{name: name, body: body}]

    if capture do
      if result.capture != nil,
        do: raise(InvalidSelectorError, "Only one of the selectors can capture using * modifier")

      %{result | parts: parts, capture: length(parts) - 1}
    else
      %{result | parts: parts}
    end
  end

  # Must be a text selector with some text before the quote.
  defp should_ignore_text_selector_quote(selector, start, index) do
    prefix = binary_part(selector, start, index - start)

    case Regex.run(~r/\A\s*text\s*=(.*)\z/, prefix) do
      [_, text] -> text != ""
      nil -> false
    end
  end

  # The reader state (`wp`, `EOL`) is threaded through: each helper returns `{value, state}`.
  def parse_attribute_selector(selector, allow_unquoted_strings) do
    chars = selector |> String.codepoints() |> List.to_tuple()
    s = %{selector: selector, chars: chars, wp: 0, allowUnquotedStrings: allow_unquoted_strings}

    {name, s} = read_identifier(s)
    s = skip_spaces(s)
    {attributes, s} = read_attributes(s, [])
    if !eol(s), do: syntax_error(s, nil)

    if name == "" and attributes == [],
      do: raise(InvalidSelectorError, "Error while parsing selector `#{selector}` - selector cannot be empty")

    %{name: name, attributes: attributes}
  end

  defp read_attributes(s, acc) do
    if next(s) == "[" do
      {attribute, s} = read_attribute(s)
      read_attributes(skip_spaces(s), acc ++ [attribute])
    else
      {acc, s}
    end
  end

  defp eol(s), do: s.wp >= tuple_size(s.chars)

  defp next(s), do: if(eol(s), do: "", else: elem(s.chars, s.wp))

  defp eat1(s), do: {next(s), %{s | wp: s.wp + 1}}

  defp syntax_error(s, stage) do
    if eol(s),
      do: raise(InvalidSelectorError, "Unexpected end of selector while parsing selector `#{s.selector}`")

    raise InvalidSelectorError,
          ~s(Error while parsing selector `#{s.selector}` - unexpected symbol "#{next(s)}" at position #{s.wp}) <>
            if(stage, do: " during " <> stage, else: "")
  end

  defp skip_spaces(s) do
    if !eol(s) and Regex.match?(~r/\A\s\z/u, next(s)), do: skip_spaces(elem(eat1(s), 1)), else: s
  end

  # https://www.w3.org/TR/css-syntax-3/#ident-token-diagram
  defp is_css_name_char(""), do: false

  defp is_css_name_char(char) do
    <<code::utf8, _::binary>> = char
    # non-ascii, digit, uppercase letter, lowercase letter, "_", "-"
    code >= 0x80 or code in ?0..?9 or code in ?A..?Z or code in ?a..?z or code == ?_ or code == ?-
  end

  defp read_identifier(s), do: read_while(skip_spaces(s), "", &is_css_name_char/1)

  defp read_while(s, result, fun) do
    if !eol(s) and fun.(next(s)) do
      {c, s} = eat1(s)
      read_while(s, result <> c, fun)
    else
      {result, s}
    end
  end

  defp read_quoted_string(s, quote) do
    {result, s} = eat1(s)
    if result != quote, do: syntax_error(s, "parsing quoted string")
    {result, s} = read_quoted_chars(s, quote, result)
    if next(s) != quote, do: syntax_error(s, "parsing quoted string")
    {c, s} = eat1(s)
    {result <> c, s}
  end

  defp read_quoted_chars(s, quote, result) do
    if !eol(s) and next(s) != quote do
      s = if next(s) == "\\", do: elem(eat1(s), 1), else: s
      {c, s} = eat1(s)
      read_quoted_chars(s, quote, result <> c)
    else
      {result, s}
    end
  end

  defp read_regular_expression(s) do
    {c, s} = eat1(s)
    if c != "/", do: syntax_error(s, "parsing regular expression")
    # https://262.ecma-international.org/11.0/#sec-literals-regular-expression-literals
    {source, s} = read_regular_expression_source(s, "", false)
    {c, s} = eat1(s)
    if c != "/", do: syntax_error(s, "parsing regular expression")
    # https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Regular_Expressions
    {flags, s} = read_while(s, "", &(&1 in ~w(d g i m s u v y)))

    try do
      {RegExp.new(source, flags), s}
    rescue
      e ->
        reraise InvalidSelectorError,
                "Error while parsing selector `#{s.selector}`: #{Exception.message(e)}",
                __STACKTRACE__
    end
  end

  defp read_regular_expression_source(s, source, in_class) do
    if eol(s) do
      {source, s}
    else
      {source, s, in_class, break} =
        cond do
          next(s) == "\\" ->
            {c, s} = eat1(s)
            if eol(s), do: syntax_error(s, "parsing regular expression")
            {source <> c, s, in_class, false}

          in_class and next(s) == "]" ->
            {source, s, false, false}

          !in_class and next(s) == "[" ->
            {source, s, true, false}

          !in_class and next(s) == "/" ->
            {source, s, in_class, true}

          true ->
            {source, s, in_class, false}
        end

      if break do
        {source, s}
      else
        {c, s} = eat1(s)
        read_regular_expression_source(s, source <> c, in_class)
      end
    end
  end

  defp read_attribute_token(s) do
    s = skip_spaces(s)

    {token, s} =
      if next(s) == "'" or next(s) == "\"" do
        {token, s} = read_quoted_string(s, next(s))
        {unquote_string(token), s}
      else
        read_identifier(s)
      end

    if token == "", do: syntax_error(s, "parsing property path")
    {token, s}
  end

  defp read_operator(s) do
    s = skip_spaces(s)
    {op, s} = if !eol(s), do: eat1(s), else: {"", s}
    {op, s} = if !eol(s) and op != "=", do: (fn {c, s} -> {op <> c, s} end).(eat1(s)), else: {op, s}
    if op not in ["=", "*=", "^=", "$=", "|=", "~="], do: syntax_error(s, "parsing operator")
    {op, s}
  end

  defp read_attribute(s) do
    # skip leading [
    {_, s} = eat1(s)

    # read attribute name:
    # foo.bar
    # 'foo'  . "ba zz"
    {token, s} = read_attribute_token(s)
    {json_path, s} = read_json_path(skip_spaces(s), [token])

    # check property is truthy: [enabled]
    if next(s) == "]" do
      {_, s} = eat1(s)
      {%{name: Enum.join(json_path, "."), jsonPath: json_path, op: "<truthy>", value: nil, caseSensitive: false}, s}
    else
      {operator, s} = read_operator(s)
      s = skip_spaces(s)

      {value, case_sensitive, s} =
        cond do
          next(s) == "/" ->
            if operator != "=",
              do:
                raise(
                  InvalidSelectorError,
                  "Error while parsing selector `#{s.selector}` - cannot use #{operator} in attribute with regular expression"
                )

            {value, s} = read_regular_expression(s)
            {value, true, s}

          next(s) == "'" or next(s) == "\"" ->
            {value, s} = read_quoted_string(s, next(s))
            value = unquote_string(value)
            s = skip_spaces(s)

            cond do
              next(s) in ["i", "I"] -> {value, false, elem(eat1(s), 1)}
              next(s) in ["s", "S"] -> {value, true, elem(eat1(s), 1)}
              true -> {value, true, s}
            end

          true ->
            {value, s} = read_while(s, "", &(is_css_name_char(&1) or &1 == "+" or &1 == "."))

            value =
              cond do
                value == "true" ->
                  true

                value == "false" ->
                  false

                !s.allowUnquotedStrings ->
                  value = to_number(value)
                  if value == :nan, do: syntax_error(s, "parsing attribute value")
                  value

                true ->
                  value
              end

            {value, true, s}
        end

      s = skip_spaces(s)
      if next(s) != "]", do: syntax_error(s, "parsing attribute value")

      {_, s} = eat1(s)

      if operator != "=" and !is_binary(value),
        do:
          raise(
            InvalidSelectorError,
            "Error while parsing selector `#{s.selector}` - cannot use #{operator} in attribute with non-string matching value - #{js_string(value)}"
          )

      {%{
         name: Enum.join(json_path, "."),
         jsonPath: json_path,
         op: operator,
         value: value,
         caseSensitive: case_sensitive
       }, s}
    end
  end

  defp read_json_path(s, json_path) do
    if next(s) == "." do
      {_, s} = eat1(s)
      {token, s} = read_attribute_token(s)
      read_json_path(skip_spaces(s), json_path ++ [token])
    else
      {json_path, s}
    end
  end

  # `.slice(1, -1)` of a quoted string: the quotes are ASCII.
  defp unquote_string(quoted), do: binary_part(quoted, 1, byte_size(quoted) - 2)

  # `+value`: JS Number(string), :nan when it is not a number.
  defp to_number(""), do: 0

  defp to_number(value) do
    case Integer.parse(value) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(value) do
          {f, ""} -> f
          _ -> :nan
        end
    end
  end

  # `${value}`
  defp js_string(%RegExp{} = re), do: RegExp.to_string(re)
  defp js_string(value), do: to_string(value)
end
