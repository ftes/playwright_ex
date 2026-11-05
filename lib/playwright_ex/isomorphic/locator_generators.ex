defmodule PlaywrightEx.Isomorphic.LocatorGenerators do
  @upstream "packages/isomorphic/locatorGenerators.ts"
  @moduledoc """
  Port of `#{@upstream}`: renders a selector as locator code. Languages are upstream's
  (`"javascript"`, `"python"`, `"java"`, `"csharp"`, `"jsonl"`) plus `"elixir"`, the facade syntax
  (`ElixirLocatorFactory`). `LocatorOptions` is a keyword list in JS insertion order (`nil` is
  `undefined`), a factory a struct whose module implements `generate_locator/5` and
  `chain_locators/2`. `RegExp` values are `PlaywrightEx.RegExp`.
  """

  import PlaywrightEx.Isomorphic.SelectorParser,
    only: [parse_attribute_selector: 2, parse_selector: 1, stringify_selector: 1, stringify_selector: 2]

  alias PlaywrightEx.RegExp

  def as_locator_description(lang, selector) do
    try do
      parsed = parse_selector(selector)
      custom_description = parse_custom_description(parsed)

      if custom_description,
        do: custom_description,
        else: hd(inner_as_locators(new_factory(lang), parsed, false, 1))
    rescue
      # Tolerate invalid input.
      _ -> selector
    end
  end

  def locator_custom_description(selector) do
    try do
      parsed = parse_selector(selector)
      parse_custom_description(parsed)
    rescue
      _ -> nil
    end
  end

  defp parse_custom_description(parsed) do
    last_part = List.last(parsed.parts)

    if last_part[:name] == "internal:describe" do
      description = JSON.decode!(last_part.body)
      if is_binary(description), do: description
    end
  end

  def as_locator(lang, selector, is_frame_locator \\ false) do
    hd(as_locators(lang, selector, is_frame_locator, 1))
  end

  def as_locators(lang, selector, is_frame_locator \\ false, max_output_size \\ 20, preferred_quote \\ nil) do
    try do
      inner_as_locators(new_factory(lang, preferred_quote), parse_selector(selector), is_frame_locator, max_output_size)
    rescue
      # Tolerate invalid input.
      _ -> [selector]
    end
  end

  defp inner_as_locators(factory, parsed, is_frame_locator, max_output_size) do
    parts = List.to_tuple(parsed.parts)
    next_base = if is_frame_locator, do: "frame-locator", else: "page"
    tokens = inner_tokens(factory, parts, 0, next_base, [], max_output_size)
    combine_tokens(factory, tokens, max_output_size)
  end

  # The `for (let index ...)` loop: `tokens` is reversed (the last token list first).
  defp inner_tokens(_factory, parts, index, _next_base, tokens, _max_output_size) when index >= tuple_size(parts),
    do: Enum.reverse(tokens)

  defp inner_tokens(factory, parts, index, next_base, tokens, max_output_size) do
    part = elem(parts, index)
    base = next_base
    next = &inner_tokens(factory, parts, index + &1, &2, &3, max_output_size)
    gen = &generate_locator(factory, &1, &2, &3, &4)

    case part_tokens(factory, part, base, max_output_size) do
      :skip ->
        next.(1, "locator", tokens)

      {:push, token_list} ->
        next.(1, "locator", [token_list | tokens])

      {:push, token_list, next_base} ->
        next.(1, next_base, [token_list | tokens])

      :enter_frame ->
        # transform last tokens from `${selector}` into `${selector}.contentFrame()` and `frameLocator(${selector})`
        [last_tokens | tokens] = tokens
        last_part = if index > 0, do: elem(parts, index - 1)

        transformed = Enum.map(last_tokens, &chain_locators(factory, [&1, gen.(base, "frame", "", [])]))

        transformed =
          if last_part.name in ["xpath", "css"],
            do:
              transformed ++
                [
                  gen.(base, "frame-locator", stringify_selector(%{parts: [last_part]}), []),
                  gen.(base, "frame-locator", stringify_selector(%{parts: [last_part]}, true), [])
                ],
            else: transformed

        next.(1, "frame-locator", [transformed | tokens])

      :default ->
        next_part = if index + 1 < tuple_size(parts), do: elem(parts, index + 1)

        selector_part = stringify_selector(%{parts: [part]})
        locator_part = gen.(base, "default", selector_part, [])

        {exact, text} =
          if next_part && next_part.name in ["internal:has-text", "internal:has-not-text"],
            do: detect_exact(next_part.body),
            else: {true, nil}

        # There is no locator equivalent for strict has-text and has-not-text, leave it as is.
        if !exact do
          next_locator_part =
            gen.(
              "locator",
              if(next_part.name == "internal:has-text", do: "has-text", else: "has-not-text"),
              text,
              exact: exact
            )

          options = if next_part.name == "internal:has-text", do: [hasText: text], else: [hasNotText: text]
          combined_part = gen.(base, "default", selector_part, options)
          # Two options:
          # - locator('div').filter({ hasText: 'foo' })
          # - locator('div', { hasText: 'foo' })
          next.(2, "locator", [[chain_locators(factory, [locator_part, next_locator_part]), combined_part] | tokens])
        else
          # Selectors can be prefixed with engine name, e.g. xpath=//foo
          locator_part_with_engine =
            if part.name in ["xpath", "css"] do
              selector_part = stringify_selector(%{parts: [part]}, true)
              gen.(base, "default", selector_part, [])
            end

          next.(1, "locator", [Enum.filter([locator_part, locator_part_with_engine], & &1) | tokens])
        end
    end
  end

  # One iteration of the loop up to the fallthrough to the default locator.
  defp part_tokens(factory, part, base, max_output_size) do
    gen = &generate_locator(factory, base, &1, &2, &3)
    inners = fn -> inner_as_locators(factory, part.body.parsed, false, max_output_size) end

    case part.name do
      "internal:describe" ->
        :skip

      "nth" ->
        cond do
          part.body == "0" -> {:push, [gen.("first", "", []), gen.("nth", "0", [])]}
          part.body == "-1" -> {:push, [gen.("last", "", []), gen.("nth", "-1", [])]}
          true -> {:push, [gen.("nth", part.body, [])]}
        end

      "visible" ->
        token_list = if part.body == "true", do: [gen.("visible", "", [])], else: []

        {:push, token_list ++ [gen.("filter-visible", part.body, []), gen.("default", "visible=#{part.body}", [])]}

      "internal:text" ->
        {exact, text} = detect_exact(part.body)
        {:push, [gen.("text", text, exact: exact)]}

      name when name in ["internal:has-text", "internal:has-not-text"] ->
        {exact, text} = detect_exact(part.body)
        # There is no locator equivalent for strict has-text, leave it as is.
        kind = if name == "internal:has-text", do: "has-text", else: "has-not-text"
        if !exact, do: {:push, [gen.(kind, text, exact: exact)]}, else: :default

      "internal:has" ->
        {:push, Enum.map(inners.(), &gen.("has", &1, []))}

      "internal:has-not" ->
        {:push, Enum.map(inners.(), &gen.("hasNot", &1, []))}

      "internal:and" ->
        {:push, Enum.map(inners.(), &gen.("and", &1, []))}

      "internal:or" ->
        {:push, Enum.map(inners.(), &gen.("or", &1, []))}

      "internal:chain" ->
        {:push, Enum.map(inners.(), &gen.("chain", &1, []))}

      "internal:label" ->
        {exact, text} = detect_exact(part.body)
        {:push, [gen.("label", text, exact: exact)]}

      "internal:role" ->
        attr_selector = parse_attribute_selector(part.body, true)

        options =
          Enum.reduce(attr_selector.attributes, [attrs: []], fn attr, options ->
            if attr.name == "name" or attr.name == "description" do
              # Only string values carry exactness, regular expressions are used as is.
              options =
                if is_binary(attr.value) do
                  if options[:exact] != nil and options[:exact] != attr.caseSensitive,
                    do:
                      raise("Conflicting exactness in internal:role selector: #{stringify_selector(%{parts: [part]})}")

                  put_option(options, :exact, attr.caseSensitive)
                else
                  options
                end

              put_option(options, if(attr.name == "name", do: :name, else: :description), attr.value)
            else
              value = if attr.name == "level" and is_binary(attr.value), do: to_number(attr.value), else: attr.value
              name = if attr.name == "include-hidden", do: "includeHidden", else: attr.name
              put_option(options, :attrs, options[:attrs] ++ [%{name: name, value: value}])
            end
          end)

        {:push, [gen.("role", attr_selector.name, options)]}

      "internal:testid" ->
        attr_selector = parse_attribute_selector(part.body, true)
        %{value: value} = hd(attr_selector.attributes)
        {:push, [gen.("test-id", value, [])]}

      "internal:attr" ->
        attr_selector = parse_attribute_selector(part.body, true)
        %{name: name, value: value, caseSensitive: case_sensitive} = hd(attr_selector.attributes)
        text = value
        exact = !!case_sensitive

        if name in ["placeholder", "alt", "title"],
          do: {:push, [gen.(name, text, exact: exact)]},
          else: :default

      "internal:control" when part.body == "any-frame" ->
        {:push, [gen.("any-frame", "", [])], "frame-locator"}

      "internal:control" when part.body == "enter-frame" ->
        :enter_frame

      _ ->
        :default
    end
  end

  defp combine_tokens(factory, tokens, max_output_size) do
    {_, result} = visit(factory, tokens, [], [], max_output_size)
    Enum.reverse(result)
  end

  # `visit(index)`: returns whether to go on, with the results so far (reversed).
  defp visit(factory, [], current_tokens, result, max_output_size) do
    result = [chain_locators(factory, Enum.reverse(current_tokens)) | result]
    {length(result) < max_output_size, result}
  end

  defp visit(factory, [token_list | rest], current_tokens, result, max_output_size) do
    Enum.reduce_while(token_list, {true, result}, fn taken, {_, result} ->
      case visit(factory, rest, [taken | current_tokens], result, max_output_size) do
        {true, result} -> {:cont, {true, result}}
        {false, result} -> {:halt, {false, result}}
      end
    end)
  end

  # `{exact, text}`: exact is `nil` (undefined) for regular expressions.
  defp detect_exact(text) do
    case Regex.run(~r/\A\/(.*)\/([dgimsuvy]*)\z/, text) do
      [_, source, flags] ->
        {nil, RegExp.new(source, flags)}

      nil ->
        cond do
          String.ends_with?(text, "\"") -> {true, JSON.decode!(text)}
          String.ends_with?(text, "\"s") -> {true, JSON.decode!(binary_part(text, 0, byte_size(text) - 1))}
          String.ends_with?(text, "\"i") -> {false, JSON.decode!(binary_part(text, 0, byte_size(text) - 1))}
          true -> {false, text}
        end
    end
  end

  # Assigns `options[key]` keeping the position of an existing key, as a JS object does.
  defp put_option(options, key, value) do
    if Keyword.has_key?(options, key),
      do: Enum.map(options, fn {k, v} -> if k == key, do: {k, value}, else: {k, v} end),
      else: options ++ [{key, value}]
  end

  # attr.value = +attr.value
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

  # factory.generateLocator(...), factory.chainLocators(...)
  defp generate_locator(factory, base, kind, body, options),
    do: factory.__struct__.generate_locator(factory, base, kind, body, options)

  defp chain_locators(factory, locators), do: factory.__struct__.chain_locators(factory, locators)

  @doc false
  # `${value}` of an option value.
  def js_string(nil), do: "null"
  def js_string(:nan), do: "NaN"
  def js_string(%RegExp{} = re), do: RegExp.to_string(re)
  def js_string(value) when is_float(value) and value == trunc(value), do: Integer.to_string(trunc(value))
  def js_string(value), do: to_string(value)

  defmodule JavaScriptLocatorFactory do
    @moduledoc false
    import PlaywrightEx.Isomorphic.StringUtils, only: [escape_with_quotes: 2, normalize_escaped_regex_quotes: 1]
    alias PlaywrightEx.Isomorphic.LocatorGenerators

    alias PlaywrightEx.RegExp

    defstruct [:preferredQuote]

    def generate_locator(this, _base, kind, body, options \\ []) do
      case kind do
        "default" ->
          cond do
            options[:hasText] != nil ->
              "locator(#{quote_text(this, body)}, { hasText: #{to_has_text(this, options[:hasText])} })"

            options[:hasNotText] != nil ->
              "locator(#{quote_text(this, body)}, { hasNotText: #{to_has_text(this, options[:hasNotText])} })"

            true ->
              "locator(#{quote_text(this, body)})"
          end

        "frame-locator" ->
          "frameLocator(#{quote_text(this, body)})"

        "frame" ->
          "contentFrame()"

        "any-frame" ->
          "frameLocator()"

        "nth" ->
          "nth(#{body})"

        "first" ->
          "first()"

        "last" ->
          "last()"

        "visible" ->
          "visible()"

        "filter-visible" ->
          "filter({ visible: #{if body == "true", do: "true", else: "false"} })"

        "role" ->
          attrs =
            [
              cond do
                LocatorGenerators.is_reg_exp(options[:name]) -> "name: #{regex_to_source_string(options[:name])}"
                is_binary(options[:name]) -> "name: #{quote_text(this, options[:name])}"
                true -> nil
              end,
              cond do
                LocatorGenerators.is_reg_exp(options[:description]) ->
                  "description: #{regex_to_source_string(options[:description])}"

                is_binary(options[:description]) ->
                  "description: #{quote_text(this, options[:description])}"

                true ->
                  nil
              end,
              if(options[:exact] && (is_binary(options[:name]) or is_binary(options[:description])), do: "exact: true")
            ]
            |> Enum.filter(& &1)

          attrs =
            attrs ++
              for %{name: name, value: value} <- options[:attrs],
                  do:
                    "#{name}: #{if is_binary(value), do: quote_text(this, value), else: LocatorGenerators.js_string(value)}"

          attr_string = if attrs != [], do: ", { #{Enum.join(attrs, ", ")} }", else: ""
          "getByRole(#{quote_text(this, body)}#{attr_string})"

        "has-text" ->
          "filter({ hasText: #{to_has_text(this, body)} })"

        "has-not-text" ->
          "filter({ hasNotText: #{to_has_text(this, body)} })"

        "has" ->
          "filter({ has: #{body} })"

        "hasNot" ->
          "filter({ hasNot: #{body} })"

        "and" ->
          "and(#{body})"

        "or" ->
          "or(#{body})"

        "chain" ->
          "locator(#{body})"

        "test-id" ->
          "getByTestId(#{to_test_id_value(this, body)})"

        "text" ->
          to_call_with_exact(this, "getByText", body, !!options[:exact])

        "alt" ->
          to_call_with_exact(this, "getByAltText", body, !!options[:exact])

        "placeholder" ->
          to_call_with_exact(this, "getByPlaceholder", body, !!options[:exact])

        "label" ->
          to_call_with_exact(this, "getByLabel", body, !!options[:exact])

        "title" ->
          to_call_with_exact(this, "getByTitle", body, !!options[:exact])

        _ ->
          raise "Unknown selector kind " <> kind
      end
    end

    def chain_locators(_this, locators) do
      Enum.join(locators, ".")
    end

    defp regex_to_source_string(re) do
      normalize_escaped_regex_quotes(RegExp.to_string(re))
    end

    defp to_call_with_exact(this, method, body, exact) do
      cond do
        LocatorGenerators.is_reg_exp(body) -> "#{method}(#{regex_to_source_string(body)})"
        exact -> "#{method}(#{quote_text(this, body)}, { exact: true })"
        true -> "#{method}(#{quote_text(this, body)})"
      end
    end

    defp to_has_text(this, body) do
      if LocatorGenerators.is_reg_exp(body), do: regex_to_source_string(body), else: quote_text(this, body)
    end

    defp to_test_id_value(this, value) do
      if LocatorGenerators.is_reg_exp(value), do: regex_to_source_string(value), else: quote_text(this, value)
    end

    # quote  -- ported as quote_text (Kernel.SpecialForms.quote/2)
    defp quote_text(this, text) do
      escape_with_quotes(text, this.preferredQuote || "'")
    end
  end

  defmodule PythonLocatorFactory do
    @moduledoc false
    import PlaywrightEx.Isomorphic.StringUtils,
      only: [escape_with_quotes: 2, normalize_escaped_regex_quotes: 1, to_snake_case: 1]

    alias PlaywrightEx.Isomorphic.LocatorGenerators

    defstruct []

    def generate_locator(_this, _base, kind, body, options \\ []) do
      case kind do
        "default" ->
          cond do
            options[:hasText] != nil ->
              "locator(#{quote_text(body)}, has_text=#{to_has_text(options[:hasText])})"

            options[:hasNotText] != nil ->
              "locator(#{quote_text(body)}, has_not_text=#{to_has_text(options[:hasNotText])})"

            true ->
              "locator(#{quote_text(body)})"
          end

        "frame-locator" ->
          "frame_locator(#{quote_text(body)})"

        "frame" ->
          "content_frame"

        "any-frame" ->
          "frame_locator()"

        "nth" ->
          "nth(#{body})"

        "first" ->
          "first"

        "last" ->
          "last"

        "visible" ->
          "visible"

        "filter-visible" ->
          "filter(visible=#{if body == "true", do: "True", else: "False"})"

        "role" ->
          attrs =
            [
              cond do
                LocatorGenerators.is_reg_exp(options[:name]) -> "name=#{regex_to_string(options[:name])}"
                is_binary(options[:name]) -> "name=#{quote_text(options[:name])}"
                true -> nil
              end,
              cond do
                LocatorGenerators.is_reg_exp(options[:description]) ->
                  "description=#{regex_to_string(options[:description])}"

                is_binary(options[:description]) ->
                  "description=#{quote_text(options[:description])}"

                true ->
                  nil
              end,
              if(options[:exact] && (is_binary(options[:name]) or is_binary(options[:description])), do: "exact=True")
            ]
            |> Enum.filter(& &1)

          attrs =
            attrs ++
              for %{name: name, value: value} <- options[:attrs] do
                value_string = if is_binary(value), do: quote_text(value), else: LocatorGenerators.js_string(value)
                value_string = if is_boolean(value), do: if(value, do: "True", else: "False"), else: value_string
                "#{to_snake_case(name)}=#{value_string}"
              end

          attr_string = if attrs != [], do: ", #{Enum.join(attrs, ", ")}", else: ""
          "get_by_role(#{quote_text(body)}#{attr_string})"

        "has-text" ->
          "filter(has_text=#{to_has_text(body)})"

        "has-not-text" ->
          "filter(has_not_text=#{to_has_text(body)})"

        "has" ->
          "filter(has=#{body})"

        "hasNot" ->
          "filter(has_not=#{body})"

        "and" ->
          "and_(#{body})"

        "or" ->
          "or_(#{body})"

        "chain" ->
          "locator(#{body})"

        "test-id" ->
          "get_by_test_id(#{to_test_id_value(body)})"

        "text" ->
          to_call_with_exact("get_by_text", body, !!options[:exact])

        "alt" ->
          to_call_with_exact("get_by_alt_text", body, !!options[:exact])

        "placeholder" ->
          to_call_with_exact("get_by_placeholder", body, !!options[:exact])

        "label" ->
          to_call_with_exact("get_by_label", body, !!options[:exact])

        "title" ->
          to_call_with_exact("get_by_title", body, !!options[:exact])

        _ ->
          raise "Unknown selector kind " <> kind
      end
    end

    def chain_locators(_this, locators) do
      Enum.join(locators, ".")
    end

    defp regex_to_string(body) do
      suffix = LocatorGenerators.regex_flags_suffix(body, "re", LocatorGenerators.regex_flag_names().python)

      source =
        body.source
        |> normalize_escaped_regex_quotes()
        |> String.replace("\\/", "/", global: false)
        |> String.replace("\"", "\\\"")

      "re.compile(r\"#{source}\"#{suffix})"
    end

    defp to_call_with_exact(method, body, exact) do
      cond do
        LocatorGenerators.is_reg_exp(body) -> "#{method}(#{regex_to_string(body)})"
        exact -> "#{method}(#{quote_text(body)}, exact=True)"
        true -> "#{method}(#{quote_text(body)})"
      end
    end

    defp to_has_text(body) do
      if LocatorGenerators.is_reg_exp(body), do: regex_to_string(body), else: "#{quote_text(body)}"
    end

    defp to_test_id_value(value) do
      if LocatorGenerators.is_reg_exp(value), do: regex_to_string(value), else: quote_text(value)
    end

    # quote  -- ported as quote_text (Kernel.SpecialForms.quote/2)
    defp quote_text(text) do
      escape_with_quotes(text, "\"")
    end
  end

  defmodule JavaLocatorFactory do
    @moduledoc false
    import PlaywrightEx.Isomorphic.StringUtils,
      only: [escape_with_quotes: 2, normalize_escaped_regex_quotes: 1, to_snake_case: 1, to_title_case: 1]

    alias PlaywrightEx.Isomorphic.LocatorGenerators

    defstruct []

    def generate_locator(_this, base, kind, body, options \\ []) do
      clazz =
        case base do
          "page" -> "Page"
          "frame-locator" -> "FrameLocator"
          "locator" -> "Locator"
        end

      case kind do
        "default" ->
          cond do
            options[:hasText] != nil ->
              "locator(#{quote_text(body)}, new #{clazz}.LocatorOptions().setHasText(#{to_has_text(options[:hasText])}))"

            options[:hasNotText] != nil ->
              "locator(#{quote_text(body)}, new #{clazz}.LocatorOptions().setHasNotText(#{to_has_text(options[:hasNotText])}))"

            true ->
              "locator(#{quote_text(body)})"
          end

        "frame-locator" ->
          "frameLocator(#{quote_text(body)})"

        "frame" ->
          "contentFrame()"

        "any-frame" ->
          "frameLocator()"

        "nth" ->
          "nth(#{body})"

        "first" ->
          "first()"

        "last" ->
          "last()"

        "visible" ->
          "visible()"

        "filter-visible" ->
          "filter(new #{clazz}.FilterOptions().setVisible(#{if body == "true", do: "true", else: "false"}))"

        "role" ->
          attrs =
            [
              cond do
                LocatorGenerators.is_reg_exp(options[:name]) -> ".setName(#{regex_to_string(options[:name])})"
                is_binary(options[:name]) -> ".setName(#{quote_text(options[:name])})"
                true -> nil
              end,
              cond do
                LocatorGenerators.is_reg_exp(options[:description]) ->
                  ".setDescription(#{regex_to_string(options[:description])})"

                is_binary(options[:description]) ->
                  ".setDescription(#{quote_text(options[:description])})"

                true ->
                  nil
              end,
              if(options[:exact] && (is_binary(options[:name]) or is_binary(options[:description])),
                do: ".setExact(true)"
              )
            ]
            |> Enum.filter(& &1)

          attrs =
            attrs ++
              for %{name: name, value: value} <- options[:attrs],
                  do:
                    ".set#{to_title_case(name)}(#{if is_binary(value), do: quote_text(value), else: LocatorGenerators.js_string(value)})"

          attr_string = if attrs != [], do: ", new #{clazz}.GetByRoleOptions()#{Enum.join(attrs, "")}", else: ""
          "getByRole(AriaRole.#{String.upcase(to_snake_case(body))}#{attr_string})"

        "has-text" ->
          "filter(new #{clazz}.FilterOptions().setHasText(#{to_has_text(body)}))"

        "has-not-text" ->
          "filter(new #{clazz}.FilterOptions().setHasNotText(#{to_has_text(body)}))"

        "has" ->
          "filter(new #{clazz}.FilterOptions().setHas(#{body}))"

        "hasNot" ->
          "filter(new #{clazz}.FilterOptions().setHasNot(#{body}))"

        "and" ->
          "and(#{body})"

        "or" ->
          "or(#{body})"

        "chain" ->
          "locator(#{body})"

        "test-id" ->
          "getByTestId(#{to_test_id_value(body)})"

        "text" ->
          to_call_with_exact(clazz, "getByText", body, !!options[:exact])

        "alt" ->
          to_call_with_exact(clazz, "getByAltText", body, !!options[:exact])

        "placeholder" ->
          to_call_with_exact(clazz, "getByPlaceholder", body, !!options[:exact])

        "label" ->
          to_call_with_exact(clazz, "getByLabel", body, !!options[:exact])

        "title" ->
          to_call_with_exact(clazz, "getByTitle", body, !!options[:exact])

        _ ->
          raise "Unknown selector kind " <> kind
      end
    end

    def chain_locators(_this, locators) do
      Enum.join(locators, ".")
    end

    defp regex_to_string(body) do
      suffix = LocatorGenerators.regex_flags_suffix(body, "Pattern", LocatorGenerators.regex_flag_names().java)
      "Pattern.compile(#{quote_text(normalize_escaped_regex_quotes(body.source))}#{suffix})"
    end

    defp to_call_with_exact(clazz, method, body, exact) do
      cond do
        LocatorGenerators.is_reg_exp(body) -> "#{method}(#{regex_to_string(body)})"
        exact -> "#{method}(#{quote_text(body)}, new #{clazz}.#{to_title_case(method)}Options().setExact(true))"
        true -> "#{method}(#{quote_text(body)})"
      end
    end

    defp to_has_text(body) do
      if LocatorGenerators.is_reg_exp(body), do: regex_to_string(body), else: quote_text(body)
    end

    defp to_test_id_value(value) do
      if LocatorGenerators.is_reg_exp(value), do: regex_to_string(value), else: quote_text(value)
    end

    # quote  -- ported as quote_text (Kernel.SpecialForms.quote/2)
    defp quote_text(text) do
      escape_with_quotes(text, "\"")
    end
  end

  defmodule CSharpLocatorFactory do
    @moduledoc false
    import PlaywrightEx.Isomorphic.StringUtils,
      only: [escape_with_quotes: 2, normalize_escaped_regex_quotes: 1, to_title_case: 1]

    alias PlaywrightEx.Isomorphic.LocatorGenerators

    defstruct []

    def generate_locator(_this, _base, kind, body, options \\ []) do
      case kind do
        "default" ->
          cond do
            options[:hasText] != nil ->
              "Locator(#{quote_text(body)}, new() { #{to_has_text(options[:hasText])} })"

            options[:hasNotText] != nil ->
              "Locator(#{quote_text(body)}, new() { #{to_has_not_text(options[:hasNotText])} })"

            true ->
              "Locator(#{quote_text(body)})"
          end

        "frame-locator" ->
          "FrameLocator(#{quote_text(body)})"

        "frame" ->
          "ContentFrame"

        "any-frame" ->
          "FrameLocator()"

        "nth" ->
          "Nth(#{body})"

        "first" ->
          "First"

        "last" ->
          "Last"

        "visible" ->
          "Visible"

        "filter-visible" ->
          "Filter(new() { Visible = #{if body == "true", do: "true", else: "false"} })"

        "role" ->
          attrs =
            [
              cond do
                LocatorGenerators.is_reg_exp(options[:name]) -> "NameRegex = #{regex_to_string(options[:name])}"
                is_binary(options[:name]) -> "Name = #{quote_text(options[:name])}"
                true -> nil
              end,
              cond do
                LocatorGenerators.is_reg_exp(options[:description]) ->
                  "DescriptionRegex = #{regex_to_string(options[:description])}"

                is_binary(options[:description]) ->
                  "Description = #{quote_text(options[:description])}"

                true ->
                  nil
              end,
              if(options[:exact] && (is_binary(options[:name]) or is_binary(options[:description])), do: "Exact = true")
            ]
            |> Enum.filter(& &1)

          attrs =
            attrs ++
              for %{name: name, value: value} <- options[:attrs],
                  do:
                    "#{to_title_case(name)} = #{if is_binary(value), do: quote_text(value), else: LocatorGenerators.js_string(value)}"

          attr_string = if attrs != [], do: ", new() { #{Enum.join(attrs, ", ")} }", else: ""
          "GetByRole(AriaRole.#{to_title_case(body)}#{attr_string})"

        "has-text" ->
          "Filter(new() { #{to_has_text(body)} })"

        "has-not-text" ->
          "Filter(new() { #{to_has_not_text(body)} })"

        "has" ->
          "Filter(new() { Has = #{body} })"

        "hasNot" ->
          "Filter(new() { HasNot = #{body} })"

        "and" ->
          "And(#{body})"

        "or" ->
          "Or(#{body})"

        "chain" ->
          "Locator(#{body})"

        "test-id" ->
          "GetByTestId(#{to_test_id_value(body)})"

        "text" ->
          to_call_with_exact("GetByText", body, !!options[:exact])

        "alt" ->
          to_call_with_exact("GetByAltText", body, !!options[:exact])

        "placeholder" ->
          to_call_with_exact("GetByPlaceholder", body, !!options[:exact])

        "label" ->
          to_call_with_exact("GetByLabel", body, !!options[:exact])

        "title" ->
          to_call_with_exact("GetByTitle", body, !!options[:exact])

        _ ->
          raise "Unknown selector kind " <> kind
      end
    end

    def chain_locators(_this, locators) do
      Enum.join(locators, ".")
    end

    defp regex_to_string(body) do
      suffix = LocatorGenerators.regex_flags_suffix(body, "RegexOptions", LocatorGenerators.regex_flag_names().csharp)
      "new Regex(#{quote_text(normalize_escaped_regex_quotes(body.source))}#{suffix})"
    end

    defp to_call_with_exact(method, body, exact) do
      cond do
        LocatorGenerators.is_reg_exp(body) -> "#{method}(#{regex_to_string(body)})"
        exact -> "#{method}(#{quote_text(body)}, new() { Exact = true })"
        true -> "#{method}(#{quote_text(body)})"
      end
    end

    defp to_has_text(body) do
      if LocatorGenerators.is_reg_exp(body),
        do: "HasTextRegex = #{regex_to_string(body)}",
        else: "HasText = #{quote_text(body)}"
    end

    defp to_test_id_value(value) do
      if LocatorGenerators.is_reg_exp(value), do: regex_to_string(value), else: quote_text(value)
    end

    defp to_has_not_text(body) do
      if LocatorGenerators.is_reg_exp(body),
        do: "HasNotTextRegex = #{regex_to_string(body)}",
        else: "HasNotText = #{quote_text(body)}"
    end

    # quote  -- ported as quote_text (Kernel.SpecialForms.quote/2)
    defp quote_text(text) do
      escape_with_quotes(text, "\"")
    end
  end

  defmodule JsonlLocatorFactory do
    @moduledoc false
    # JSON objects keep their key order: built and parsed as `{:object, [{key, value}]}`.

    alias PlaywrightEx.RegExp

    defstruct []

    def generate_locator(_this, _base, kind, body, options \\ []) do
      stringify({:object, [{"kind", kind}, {"body", body}, {"options", options_object(options)}]})
    end

    def chain_locators(_this, locators) do
      objects = Enum.map(locators, &parse/1)
      # A locator may already be a chain, e.g. `contentFrame()` produces one. Append to its tail.
      stringify(
        List.foldr(objects, nil, fn object, next -> if next, do: append_to_tail(object, next), else: object end)
      )
    end

    defp append_to_tail({:object, pairs}, next) do
      case List.keyfind(pairs, "next", 0) do
        {"next", tail} -> {:object, List.keyreplace(pairs, "next", 0, {"next", append_to_tail(tail, next)})}
        nil -> {:object, pairs ++ [{"next", next}]}
      end
    end

    # JSON.parse
    defp parse(json) do
      decoders = %{
        object_start: fn _ -> [] end,
        object_push: fn key, value, acc -> [{key, value} | acc] end,
        object_finish: fn acc, old -> {{:object, Enum.reverse(acc)}, old} end,
        null: nil
      }

      {value, :ok, ""} = :json.decode(json, :ok, decoders)
      value
    end

    # JSON.stringify: maps (attrs) are objects, a RegExp `{}`.
    defp stringify({:object, pairs}),
      do: "{" <> Enum.map_join(pairs, ",", fn {key, value} -> JSON.encode!(key) <> ":" <> stringify(value) end) <> "}"

    defp stringify(%RegExp{}), do: "{}"

    defp stringify(map) when is_map(map),
      do: stringify({:object, Enum.map(map, fn {key, value} -> {to_string(key), value} end)})

    defp stringify(list) when is_list(list), do: "[" <> Enum.map_join(list, ",", &stringify/1) <> "]"
    defp stringify(value), do: JSON.encode!(value)

    # LocatorOptions as an object: `nil` entries are undefined.
    defp options_object(options), do: {:object, for({key, value} <- options, value != nil, do: {to_string(key), value})}
  end

  defmodule ElixirLocatorFactory do
    @moduledoc false
    # Elixir only: the facade syntax a user would paste, one pipe per chain, starting from `page`
    # (`Page.get_by_role(page, :button, name: "Submit") |> Locator.first()`). Option keys are
    # snake_case, roles atoms, regular expressions `~r` sigils (flags beyond `imsu` dropped, `v` is `u`).
    import PlaywrightEx.Isomorphic.StringUtils, only: [normalize_escaped_regex_quotes: 1, to_snake_case: 1]
    alias PlaywrightEx.Isomorphic.LocatorGenerators

    defstruct []

    def generate_locator(_this, base, kind, body, options \\ []) do
      case kind do
        "default" ->
          cond do
            options[:hasText] != nil ->
              call(base, "locator", [quote_text(body), "has_text: #{to_has_text(options[:hasText])}"])

            options[:hasNotText] != nil ->
              call(base, "locator", [quote_text(body), "has_not_text: #{to_has_text(options[:hasNotText])}"])

            true ->
              call(base, "locator", [quote_text(body)])
          end

        "frame-locator" ->
          call(base, "frame_locator", [quote_text(body)])

        "frame" ->
          call(base, "content_frame", [])

        "any-frame" ->
          call(base, "frame_locator", [])

        "nth" ->
          call(base, "nth", [body])

        "first" ->
          call(base, "first", [])

        "last" ->
          call(base, "last", [])

        "visible" ->
          call(base, "visible", [])

        "filter-visible" ->
          call(base, "filter", ["visible: #{if body == "true", do: "true", else: "false"}"])

        "role" ->
          attrs =
            [
              if(options[:name] != nil, do: "name: #{to_has_text(options[:name])}"),
              if(options[:description] != nil, do: "description: #{to_has_text(options[:description])}"),
              if(options[:exact] && (is_binary(options[:name]) or is_binary(options[:description])), do: "exact: true")
            ]
            |> Enum.filter(& &1)

          attrs =
            attrs ++
              for %{name: name, value: value} <- options[:attrs], do: "#{key(to_snake_case(name))} #{literal(value)}"

          call(base, "get_by_role", [atom(body) | attrs])

        "has-text" ->
          call(base, "filter", ["has_text: #{to_has_text(body)}"])

        "has-not-text" ->
          call(base, "filter", ["has_not_text: #{to_has_text(body)}"])

        "has" ->
          call(base, "filter", ["has: #{body}"])

        "hasNot" ->
          call(base, "filter", ["has_not: #{body}"])

        "and" ->
          call(base, "and_", [body])

        "or" ->
          call(base, "or_", [body])

        "chain" ->
          call(base, "locator", [body])

        "test-id" ->
          call(base, "get_by_test_id", [to_has_text(body)])

        "text" ->
          to_call_with_exact(base, "get_by_text", body, !!options[:exact])

        "alt" ->
          to_call_with_exact(base, "get_by_alt_text", body, !!options[:exact])

        "placeholder" ->
          to_call_with_exact(base, "get_by_placeholder", body, !!options[:exact])

        "label" ->
          to_call_with_exact(base, "get_by_label", body, !!options[:exact])

        "title" ->
          to_call_with_exact(base, "get_by_title", body, !!options[:exact])

        _ ->
          raise "Unknown selector kind " <> kind
      end
    end

    def chain_locators(_this, locators) do
      Enum.join(locators, " |> ")
    end

    # `Page.x(page, ...)` starts a chain, `Locator.x(...)` and `FrameLocator.x(...)` are piped into.
    defp call(base, function, args) do
      {module, receiver} =
        case base do
          "page" -> {"Page", ["page"]}
          "locator" -> {"Locator", []}
          "frame-locator" -> {"FrameLocator", []}
        end

      "#{module}.#{function}(#{Enum.join(receiver ++ args, ", ")})"
    end

    defp to_call_with_exact(base, function, body, exact) do
      cond do
        LocatorGenerators.is_reg_exp(body) -> call(base, function, [regex_to_sigil(body)])
        exact -> call(base, function, [quote_text(body), "exact: true"])
        true -> call(base, function, [quote_text(body)])
      end
    end

    defp to_has_text(body) do
      if LocatorGenerators.is_reg_exp(body), do: regex_to_sigil(body), else: quote_text(body)
    end

    defp regex_to_sigil(re) do
      source = re.source |> normalize_escaped_regex_quotes() |> String.replace("\#{", "\\\#{")
      flags = for <<flag <- re.flags>>, flag in ~c"imsuv", into: "", do: if(flag == ?v, do: "u", else: <<flag>>)
      "~r/#{source}/#{flags}"
    end

    # A role atom literal (`:button`), quoted if it is no plain identifier.
    defp atom(name) do
      if Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, name), do: ":" <> name, else: ":" <> quote_text(name)
    end

    defp key(name) do
      if Regex.match?(~r/\A[a-z_][a-zA-Z0-9_]*\z/, name), do: name <> ":", else: quote_text(name) <> ":"
    end

    defp literal(value) when is_binary(value), do: quote_text(value)
    defp literal(nil), do: "nil"
    defp literal(value) when is_float(value) and value == trunc(value), do: Integer.to_string(trunc(value))
    defp literal(value), do: inspect(value)

    # quote  -- ported as quote_text (Kernel.SpecialForms.quote/2)
    defp quote_text(text), do: inspect(text, binaries: :as_strings, printable_limit: :infinity)
  end

  defp new_factory(lang, preferred_quote \\ nil) do
    factory = Map.fetch!(generators(), lang)

    if factory == JavaScriptLocatorFactory,
      do: %JavaScriptLocatorFactory{preferredQuote: preferred_quote},
      else: struct(factory)
  end

  defp generators do
    %{
      "javascript" => JavaScriptLocatorFactory,
      "python" => PythonLocatorFactory,
      "java" => JavaLocatorFactory,
      "csharp" => CSharpLocatorFactory,
      "jsonl" => JsonlLocatorFactory,
      # Elixir only
      "elixir" => ElixirLocatorFactory
    }
  end

  # Regular expression flags supported by the Python, Java and C# locators.
  @doc false
  def regex_flag_names do
    %{
      python: %{"i" => "IGNORECASE", "m" => "MULTILINE", "s" => "DOTALL"},
      java: %{"i" => "CASE_INSENSITIVE", "m" => "MULTILINE", "s" => "DOTALL"},
      csharp: %{"i" => "IgnoreCase", "m" => "Multiline", "s" => "Singleline"}
    }
  end

  # E.g. `, re.IGNORECASE | re.MULTILINE`.
  @doc false
  def regex_flags_suffix(body, flags_enum, names) do
    flags = for flag <- String.codepoints(body.flags), Map.has_key?(names, flag), do: "#{flags_enum}.#{names[flag]}"
    if flags != [], do: ", #{Enum.join(flags, " | ")}", else: ""
  end

  @doc false
  def is_reg_exp(obj), do: is_struct(obj, RegExp)
end
