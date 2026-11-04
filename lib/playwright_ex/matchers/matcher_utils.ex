defmodule PlaywrightEx.Matchers.MatcherUtils do
  @moduledoc """
  The parts of `jest-matcher-utils` (with `pretty-format` and `jest-diff`) that the matchers use
  as `this.utils` (`expectLibrary.ts` `utils`). Elixir only: upstream takes them from npm, they
  are not in the Playwright repository, so this is no line-by-line port.

  Deviations: no colors (the `*_color` functions return the text as is; upstream tests strip
  them). JS values are Elixir terms as the client parses them: `nil` is `undefined`, `:null` is
  `null`, lists are arrays, maps are objects, `Regex` is `RegExp`. Multi-line strings are diffed
  line by line (`diffStringsUnified` aligns a character diff, which gives the same lines for
  most inputs).
  """

  @max_diff_string_length 20_000
  @max_length 10_000
  @context_lines 5

  def dim_color(text), do: text
  def received_color(text), do: text
  def inverted_color(text), do: text
  def expected_color(text), do: text

  def print_expected(value), do: expected_color(replace_trailing_spaces(stringify(value)))
  def print_received(object), do: received_color(replace_trailing_spaces(stringify(object)))

  def print_with_type(name, value, print) do
    type = get_type(value)
    has_type = if type not in ["null", "undefined"], do: "#{name} has type:  #{type}\n", else: ""
    has_value = "#{name} has value: #{print.(value)}"
    has_type <> has_value
  end

  def get_label_printer(labels) do
    max_length = labels |> Enum.map(&String.length/1) |> Enum.max(fn -> 0 end)
    fn label -> "#{label}: #{String.duplicate(" ", max_length - String.length(label))}" end
  end

  def print_diff_or_stringify(expected, received, expected_label, received_label, expand) do
    cond do
      is_binary(expected) and is_binary(received) and expected != "" and received != "" and
        String.length(expected) <= @max_diff_string_length and
        String.length(received) <= @max_diff_string_length and expected != received ->
        if String.contains?(expected, "\n") or String.contains?(received, "\n") do
          diff_lines_unified(String.split(expected, "\n"), String.split(received, "\n"), %{
            a_annotation: expected_label,
            b_annotation: received_label,
            expand: expand,
            placeholder: "↵"
          })
        else
          # Without colors the common and changed substrings are the strings themselves.
          print_label = get_label_printer([expected_label, received_label])

          print_label.(expected_label) <>
            print_expected(expected) <> "\n" <> print_label.(received_label) <> print_received(received)
        end

      difference =
          line_diffable?(expected, received) && diff(expected, received, expected_label, received_label, expand) ->
        difference

      true ->
        print_label = get_label_printer([expected_label, received_label])
        expected_line = print_label.(expected_label) <> print_expected(expected)

        received_line =
          print_label.(received_label) <>
            if stringify(expected) == stringify(received),
              do: "serializes to the same string",
              else: print_received(received)

        expected_line <> "\n" <> received_line
    end
  end

  def stringify(object, max_depth \\ 10, max_width \\ 10) do
    result = pretty_format(object, %{min: true, max_depth: max_depth, max_width: max_width, indent: ""}, "", 0)

    cond do
      String.length(result) >= @max_length and max_depth > 1 -> stringify(object, div(max_depth, 2), max_width)
      String.length(result) >= @max_length and max_width > 1 -> stringify(object, max_depth, div(max_width, 2))
      true -> result
    end
  end

  # --- jest-matcher-utils internals ---------------------------------------------

  defp replace_trailing_spaces(text),
    do: Regex.replace(~r/\s+$/m, text, fn spaces -> String.duplicate("·", String.length(spaces)) end)

  defp get_type(nil), do: "undefined"
  defp get_type(:null), do: "null"
  defp get_type(value) when value in [:nan, :infinity, :neg_infinity], do: "number"
  defp get_type(value) when is_boolean(value), do: "boolean"
  defp get_type(value) when is_number(value), do: "number"
  defp get_type(value) when is_binary(value), do: "string"
  defp get_type(value) when is_list(value), do: "array"
  defp get_type(value) when is_function(value), do: "function"
  defp get_type(%Regex{}), do: "regexp"
  defp get_type(value) when is_atom(value), do: "symbol"
  defp get_type(_value), do: "object"

  defp line_diffable?(expected, received) do
    expected_type = get_type(expected)

    cond do
      expected_type != get_type(received) -> false
      not (is_list(expected) or is_map(expected)) -> false
      expected_type in ["regexp", "function"] -> false
      true -> true
    end
  end

  # jest-diff `diff` for objects: compare the zero-indent forms, show the indented ones.
  defp diff(a, b, a_annotation, b_annotation, expand) do
    a_compare = format(a, "")
    b_compare = format(b, "")

    if a_compare != b_compare do
      diff_lines_unified2(
        String.split(format(a, "  "), "\n"),
        String.split(format(b, "  "), "\n"),
        String.split(a_compare, "\n"),
        String.split(b_compare, "\n"),
        %{a_annotation: a_annotation, b_annotation: b_annotation, expand: expand, placeholder: ""}
      )
    end
  end

  defp format(value, indent),
    do: pretty_format(value, %{min: false, max_depth: :infinity, max_width: :infinity, indent: indent}, "", 0)

  # --- jest-diff ---------------------------------------------------------------

  defp diff_lines_unified(a_lines, b_lines, options) do
    a_lines = if a_lines == [""], do: [], else: a_lines
    b_lines = if b_lines == [""], do: [], else: b_lines
    print_diff_lines(diff_lines_raw(a_lines, b_lines), options)
  end

  defp diff_lines_unified2(a_display, b_display, a_compare, b_compare, options) do
    a_display = List.to_tuple(a_display)
    b_display = List.to_tuple(b_display)

    {diffs, _, _} =
      diff_lines_raw(a_compare, b_compare)
      |> Enum.reduce({[], 0, 0}, fn
        {:eq, _}, {acc, a, b} -> {[{:eq, elem(b_display, b)} | acc], a + 1, b + 1}
        {:del, _}, {acc, a, b} -> {[{:del, elem(a_display, a)} | acc], a + 1, b}
        {:ins, _}, {acc, a, b} -> {[{:ins, elem(b_display, b)} | acc], a, b + 1}
      end)

    print_diff_lines(Enum.reverse(diffs), options)
  end

  defp diff_lines_raw(a_lines, b_lines) do
    for {op, lines} <- List.myers_difference(a_lines, b_lines), line <- lines, do: {op, line}
  end

  defp print_diff_lines(diffs, options) do
    print_annotation(options, count_changes(diffs)) <>
      if(options.expand,
        do: join_aligned_diffs_expand(diffs, options),
        else: join_aligned_diffs_no_expand(diffs, options)
      )
  end

  defp count_changes(diffs) do
    %{a: Enum.count(diffs, &(elem(&1, 0) == :del)), b: Enum.count(diffs, &(elem(&1, 0) == :ins))}
  end

  defp print_annotation(%{a_annotation: a_annotation, b_annotation: b_annotation}, change_counts) do
    a_count = Integer.to_string(change_counts.a)
    b_count = Integer.to_string(change_counts.b)
    # Padding right aligns the ends of the annotations.
    ba_annotation_length_diff = String.length(b_annotation) - String.length(a_annotation)
    a_annotation_padding = String.duplicate(" ", max(0, ba_annotation_length_diff))
    b_annotation_padding = String.duplicate(" ", max(0, -ba_annotation_length_diff))
    # Padding left aligns the ends of the counts.
    ba_count_length_diff = String.length(b_count) - String.length(a_count)
    a_count_padding = String.duplicate(" ", max(0, ba_count_length_diff))
    b_count_padding = String.duplicate(" ", max(0, -ba_count_length_diff))
    a_rest = "#{a_annotation_padding}  - #{a_count_padding}#{a_count}"
    b_rest = "#{b_annotation_padding}  + #{b_count_padding}#{b_count}"
    "- #{a_annotation}#{a_rest}\n+ #{b_annotation}#{b_rest}\n\n"
  end

  defp join_aligned_diffs_expand(diffs, options) do
    last = length(diffs) - 1

    diffs
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {d, i} -> print_line(d, i == 0 or i == last, options) end)
  end

  defp print_line({:eq, line}, first_or_last?, options), do: print_diff_line(line, first_or_last?, " ", options)
  defp print_line({:del, line}, first_or_last?, options), do: print_diff_line(line, first_or_last?, "-", options)
  defp print_line({:ins, line}, first_or_last?, options), do: print_diff_line(line, first_or_last?, "+", options)

  defp print_diff_line(line, first_or_last?, indicator, options) do
    cond do
      line != "" -> "#{indicator} #{line}"
      indicator != " " -> indicator
      first_or_last? and options.placeholder != "" -> "#{indicator} #{options.placeholder}"
      true -> ""
    end
  end

  # Common lines around changes, at most `@context_lines`; patch marks where lines are omitted.
  defp join_aligned_diffs_no_expand(diffs, options) do
    diffs = List.to_tuple(diffs)
    i_length = tuple_size(diffs)
    n2 = @context_lines * 2
    runs = runs(diffs)

    {j_length, excess_at_start_or_end, n_excesses_between} =
      Enum.reduce(runs, {i_length, false, 0}, fn
        {:eq, i_start, i}, {j, at_ends, between} ->
          n = i - i_start

          cond do
            i_start == 0 and i > @context_lines -> {j - (i - @context_lines), true, between}
            i_start == 0 -> {j, at_ends, between}
            i == i_length and n > @context_lines -> {j - (n - @context_lines), true, between}
            i == i_length -> {j, at_ends, between}
            n > n2 -> {j - (n - n2), at_ends, between + 1}
            true -> {j, at_ends, between}
          end

        _change, acc ->
          acc
      end)

    has_patch = n_excesses_between != 0 or excess_at_start_or_end

    j_length =
      cond do
        n_excesses_between != 0 -> j_length + n_excesses_between + 1
        excess_at_start_or_end -> j_length + 1
        true -> j_length
      end

    state = %{
      lines: if(has_patch, do: [""], else: []),
      j_last: j_length - 1,
      patch_mark: 0,
      a_start: 0,
      b_start: 0,
      a_end: 0,
      b_end: 0,
      options: options
    }

    state =
      Enum.reduce(runs, state, fn
        {:eq, i_start, i}, st ->
          n_common = i - i_start

          cond do
            i_start == 0 ->
              i_start = if i > @context_lines, do: i - @context_lines, else: i_start

              st =
                if i > @context_lines,
                  do: %{st | a_start: i_start, b_start: i_start, a_end: i_start, b_end: i_start},
                  else: st

              push_range(st, diffs, i_start, i)

            i == i_length ->
              i_end = if n_common > @context_lines, do: i_start + @context_lines, else: i
              push_range(st, diffs, i_start, i_end)

            n_common > n2 ->
              st = push_range(st, diffs, i_start, i_start + @context_lines)
              st = set_patch_mark(st)
              st = %{st | patch_mark: length(st.lines), lines: st.lines ++ [""]}
              n_omit = n_common - n2
              a_start = st.a_end + n_omit
              b_start = st.b_end + n_omit
              st = %{st | a_start: a_start, b_start: b_start, a_end: a_start, b_end: b_start}
              push_range(st, diffs, i - @context_lines, i)

            true ->
              push_range(st, diffs, i_start, i)
          end

        {_change, i_start, i}, st ->
          push_range(st, diffs, i_start, i)
      end)

    state = if has_patch, do: set_patch_mark(state), else: state
    Enum.join(state.lines, "\n")
  end

  # Runs of equal / changed diffs: {:eq | :change, start, end}.
  defp runs(diffs) do
    diffs
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.chunk_by(fn {{op, _}, _} -> op == :eq end)
    |> Enum.map(fn [{{op, _}, start} | _] = chunk ->
      {if(op == :eq, do: :eq, else: :change), start, start + length(chunk)}
    end)
  end

  defp push_range(st, diffs, from, to) when from < to do
    Enum.reduce(from..(to - 1)//1, st, fn i, st -> push_line(st, elem(diffs, i)) end)
  end

  defp push_range(st, _diffs, _from, _to), do: st

  defp push_line(st, {op, _} = d) do
    j = length(st.lines)
    st = %{st | lines: st.lines ++ [print_line(d, j == 0 or j == st.j_last, st.options)]}

    case op do
      :eq -> %{st | a_end: st.a_end + 1, b_end: st.b_end + 1}
      :del -> %{st | a_end: st.a_end + 1}
      :ins -> %{st | b_end: st.b_end + 1}
    end
  end

  defp set_patch_mark(st) do
    mark = "@@ -#{st.a_start + 1},#{st.a_end - st.a_start} +#{st.b_start + 1},#{st.b_end - st.b_start} @@"
    %{st | lines: List.replace_at(st.lines, st.patch_mark, mark)}
  end

  # --- pretty-format -------------------------------------------------------------

  defp pretty_format(nil, _config, _indentation, _depth), do: "undefined"
  defp pretty_format(:null, _config, _indentation, _depth), do: "null"
  defp pretty_format(value, _config, _indentation, _depth) when is_boolean(value), do: to_string(value)
  defp pretty_format(value, _config, _indentation, _depth) when is_integer(value), do: Integer.to_string(value)
  defp pretty_format(value, _config, _indentation, _depth) when is_float(value), do: print_number(value)
  defp pretty_format(:nan, _config, _indentation, _depth), do: "NaN"
  defp pretty_format(:infinity, _config, _indentation, _depth), do: "Infinity"
  defp pretty_format(:neg_infinity, _config, _indentation, _depth), do: "-Infinity"

  defp pretty_format(value, _config, _indentation, _depth) when is_binary(value),
    do: ~s(") <> String.replace(value, ~r/"|\\/, "\\\\\\0") <> ~s(")

  defp pretty_format(%Regex{} = re, _config, _indentation, _depth),
    do: "/#{Regex.source(re)}/#{PlaywrightEx.Protocol.Serializers.regex_flags(re)}"

  defp pretty_format(value, _config, _indentation, _depth) when is_function(value), do: "[Function anonymous]"
  defp pretty_format(value, _config, _indentation, _depth) when is_atom(value), do: "Symbol(#{value})"

  defp pretty_format(value, config, indentation, depth) when is_list(value) do
    cond do
      depth >= config.max_depth -> "[Array]"
      config.min -> "[" <> print_list_items(value, config, indentation, depth) <> "]"
      true -> "Array [" <> print_list_items(value, config, indentation, depth) <> "]"
    end
  end

  defp pretty_format(value, config, indentation, depth) when is_map(value) and not is_struct(value) do
    cond do
      depth >= config.max_depth -> "[Object]"
      config.min -> "{" <> print_object_properties(value, config, indentation, depth) <> "}"
      true -> "Object {" <> print_object_properties(value, config, indentation, depth) <> "}"
    end
  end

  defp pretty_format(value, _config, _indentation, _depth), do: inspect(value)

  defp print_list_items([], _config, _indentation, _depth), do: ""

  defp print_list_items(list, config, indentation, depth) do
    {items, more?} =
      if config.max_width != :infinity and length(list) > config.max_width,
        do: {Enum.take(list, config.max_width), true},
        else: {list, false}

    items = Enum.map(items, &pretty_format(&1, config, indentation <> config.indent, depth + 1))
    items = if more?, do: items ++ ["…"], else: items
    join_items(items, config, indentation)
  end

  defp print_object_properties(map, _config, _indentation, _depth) when map_size(map) == 0, do: ""

  defp print_object_properties(map, config, indentation, depth) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort()
    |> Enum.map(fn {key, value} ->
      pretty_format(key, config, indentation, depth) <>
        ": " <> pretty_format(value, config, indentation <> config.indent, depth + 1)
    end)
    |> join_items(config, indentation)
  end

  defp join_items(items, %{min: true}, _indentation), do: Enum.join(items, ", ")

  defp join_items(items, config, indentation) do
    inner = indentation <> config.indent
    "\n" <> Enum.map_join(items, "", &(inner <> &1 <> ",\n")) <> indentation
  end

  # JS `String(number)`: integral floats have no fraction; `-0` prints as such.
  defp print_number(+0.0), do: "0"
  defp print_number(-0.0), do: "-0"
  defp print_number(value) when value == trunc(value) and abs(value) < 1.0e21, do: Integer.to_string(trunc(value))
  defp print_number(value), do: Float.to_string(value)
end
