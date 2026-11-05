defmodule PlaywrightEx.Matchers.Matchers do
  @upstream "packages/playwright/src/matchers/matchers.ts"
  @moduledoc """
  Port of `#{@upstream}`: the web-first matchers (`toHaveText`, ...). `this` is the matcher state
  (`PlaywrightEx.Matchers.Expect`), options are maps with the JS keys, `RegExp` is a `Regex` or a
  `PlaywrightEx.RegExp`.
  The public form is the generated `PlaywrightEx.Expect`.

  Deviations: no test runner (`toPass` and the step title suffix are not ported).
  """

  alias PlaywrightEx.Client.APIResponse
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.MimeType
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Matchers.MatcherHint
  alias PlaywrightEx.Matchers.ToBeTruthy
  alias PlaywrightEx.Matchers.ToEqual
  alias PlaywrightEx.Matchers.ToHaveURL
  alias PlaywrightEx.Matchers.ToMatchText
  alias PlaywrightEx.RegExp
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.Runtime.Promise

  defp serialize_expected_text_values(items, options \\ %{}) do
    Enum.map(items, fn i ->
      {regex_source, regex_flags} = RegExp.to_js(i)

      %{
        string: if(is_binary(i), do: i),
        regexSource: regex_source,
        regexFlags: regex_flags,
        matchSubstring: options[:matchSubstring],
        ignoreCase: options[:ignoreCase],
        normalizeWhiteSpace: options[:normalizeWhiteSpace]
      }
    end)
  end

  def to_be_attached(this, locator, options \\ nil) do
    attached = !options or options[:attached] == nil or options.attached
    expected = if attached, do: "attached", else: "detached"
    arg = if attached, do: "", else: "{ attached: false }"

    ToBeTruthy.to_be_truthy(
      this,
      "toBeAttached",
      locator,
      "Locator",
      expected,
      arg,
      fn is_not, timeout, signal ->
        Locator._expect(locator, if(attached, do: "to.be.attached", else: "to.be.detached"), %{
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      options
    )
  end

  def to_be_checked(this, locator, options \\ nil) do
    checked = options[:checked]
    indeterminate = options[:indeterminate]
    expected_value = %{checked: checked, indeterminate: indeterminate}

    {expected, arg} =
      if options[:indeterminate] do
        {"indeterminate", "{ indeterminate: true }"}
      else
        {if(options[:checked] == false, do: "unchecked", else: "checked"),
         if(options[:checked] == false, do: "{ checked: false }", else: "")}
      end

    ToBeTruthy.to_be_truthy(
      this,
      "toBeChecked",
      locator,
      "Locator",
      expected,
      arg,
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.be.checked", %{
          isNot: is_not,
          timeout: timeout,
          expectedValue: expected_value,
          signal: signal,
          title: this.title
        })
      end,
      options
    )
  end

  def to_be_disabled(this, locator, options \\ nil) do
    ToBeTruthy.to_be_truthy(
      this,
      "toBeDisabled",
      locator,
      "Locator",
      "disabled",
      "",
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.be.disabled", %{isNot: is_not, timeout: timeout, signal: signal, title: this.title})
      end,
      options
    )
  end

  def to_be_editable(this, locator, options \\ nil) do
    editable = !options or options[:editable] == nil or options.editable
    expected = if editable, do: "editable", else: "readOnly"
    arg = if editable, do: "", else: "{ editable: false }"

    ToBeTruthy.to_be_truthy(
      this,
      "toBeEditable",
      locator,
      "Locator",
      expected,
      arg,
      fn is_not, timeout, signal ->
        Locator._expect(locator, if(editable, do: "to.be.editable", else: "to.be.readonly"), %{
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      options
    )
  end

  def to_be_empty(this, locator, options \\ nil) do
    ToBeTruthy.to_be_truthy(
      this,
      "toBeEmpty",
      locator,
      "Locator",
      "empty",
      "",
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.be.empty", %{isNot: is_not, timeout: timeout, signal: signal, title: this.title})
      end,
      options
    )
  end

  def to_be_enabled(this, locator, options \\ nil) do
    enabled = !options or options[:enabled] == nil or options.enabled
    expected = if enabled, do: "enabled", else: "disabled"
    arg = if enabled, do: "", else: "{ enabled: false }"

    ToBeTruthy.to_be_truthy(
      this,
      "toBeEnabled",
      locator,
      "Locator",
      expected,
      arg,
      fn is_not, timeout, signal ->
        Locator._expect(locator, if(enabled, do: "to.be.enabled", else: "to.be.disabled"), %{
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      options
    )
  end

  def to_be_focused(this, locator, options \\ nil) do
    ToBeTruthy.to_be_truthy(
      this,
      "toBeFocused",
      locator,
      "Locator",
      "focused",
      "",
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.be.focused", %{isNot: is_not, timeout: timeout, signal: signal, title: this.title})
      end,
      options
    )
  end

  def to_be_hidden(this, locator, options \\ nil) do
    ToBeTruthy.to_be_truthy(
      this,
      "toBeHidden",
      locator,
      "Locator",
      "hidden",
      "",
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.be.hidden", %{isNot: is_not, timeout: timeout, signal: signal, title: this.title})
      end,
      options
    )
  end

  def to_be_visible(this, locator, options \\ nil) do
    visible = !options or options[:visible] == nil or options.visible
    expected = if visible, do: "visible", else: "hidden"
    arg = if visible, do: "", else: "{ visible: false }"

    ToBeTruthy.to_be_truthy(
      this,
      "toBeVisible",
      locator,
      "Locator",
      expected,
      arg,
      fn is_not, timeout, signal ->
        Locator._expect(locator, if(visible, do: "to.be.visible", else: "to.be.hidden"), %{
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      options
    )
  end

  def to_be_in_viewport(this, locator, options \\ nil) do
    ToBeTruthy.to_be_truthy(
      this,
      "toBeInViewport",
      locator,
      "Locator",
      "in viewport",
      "",
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.be.in.viewport", %{
          isNot: is_not,
          expectedNumber: options[:ratio],
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      options
    )
  end

  def to_contain_text(this, locator, expected, options \\ %{}) do
    options = options || %{}

    if is_list(expected) do
      ToEqual.to_equal(
        this,
        "toContainText",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text =
            serialize_expected_text_values(expected, %{
              matchSubstring: true,
              normalizeWhiteSpace: true,
              ignoreCase: options[:ignoreCase]
            })

          Locator._expect(locator, "to.contain.text.array", %{
            expectedText: expected_text,
            isNot: is_not,
            useInnerText: options[:useInnerText],
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        Map.put(options, :contains, true)
      )
    else
      ToMatchText.to_match_text(
        this,
        "toContainText",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text =
            serialize_expected_text_values([expected], %{
              matchSubstring: true,
              normalizeWhiteSpace: true,
              ignoreCase: options[:ignoreCase]
            })

          Locator._expect(locator, "to.have.text", %{
            expectedText: expected_text,
            isNot: is_not,
            useInnerText: options[:useInnerText],
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        Map.put(options, :matchSubstring, true)
      )
    end
  end

  def to_have_accessible_description(this, locator, expected, options \\ nil) do
    ToMatchText.to_match_text(
      this,
      "toHaveAccessibleDescription",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text =
          serialize_expected_text_values([expected], %{ignoreCase: options[:ignoreCase], normalizeWhiteSpace: true})

        Locator._expect(locator, "to.have.accessible.description", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_accessible_name(this, locator, expected, options \\ nil) do
    ToMatchText.to_match_text(
      this,
      "toHaveAccessibleName",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text =
          serialize_expected_text_values([expected], %{ignoreCase: options[:ignoreCase], normalizeWhiteSpace: true})

        Locator._expect(locator, "to.have.accessible.name", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_accessible_error_message(this, locator, expected, options \\ nil) do
    ToMatchText.to_match_text(
      this,
      "toHaveAccessibleErrorMessage",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text =
          serialize_expected_text_values([expected], %{ignoreCase: options[:ignoreCase], normalizeWhiteSpace: true})

        Locator._expect(locator, "to.have.accessible.error.message", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_attribute(this, locator, name, expected, options \\ nil) do
    # Update params for the case toHaveAttribute(name, options);
    {expected, options} =
      if !options and is_map(expected) and not RegExp.reg_exp?(expected),
        do: {nil, expected},
        else: {expected, options}

    if expected == nil do
      ToBeTruthy.to_be_truthy(
        this,
        "toHaveAttribute",
        locator,
        "Locator",
        "have attribute",
        "",
        fn is_not, timeout, signal ->
          Locator._expect(locator, "to.have.attribute", %{
            expressionArg: name,
            isNot: is_not,
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        options
      )
    else
      ToMatchText.to_match_text(
        this,
        "toHaveAttribute",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text = serialize_expected_text_values([expected], %{ignoreCase: options[:ignoreCase]})

          Locator._expect(locator, "to.have.attribute.value", %{
            expressionArg: name,
            expectedText: expected_text,
            isNot: is_not,
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    end
  end

  def to_have_class(this, locator, expected, options \\ nil) do
    if is_list(expected) do
      ToEqual.to_equal(
        this,
        "toHaveClass",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text = serialize_expected_text_values(expected)

          Locator._expect(locator, "to.have.class.array", %{
            expectedText: expected_text,
            isNot: is_not,
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    else
      ToMatchText.to_match_text(
        this,
        "toHaveClass",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text = serialize_expected_text_values([expected])

          Locator._expect(locator, "to.have.class", %{
            expectedText: expected_text,
            isNot: is_not,
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    end
  end

  def to_contain_class(this, locator, expected, options \\ nil) do
    if is_list(expected) do
      if Enum.any?(expected, &RegExp.reg_exp?(&1)),
        do: raise(~s("expected" argument in toContainClass cannot contain RegExp values))

      ToEqual.to_equal(
        this,
        "toContainClass",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text = serialize_expected_text_values(expected)

          Locator._expect(locator, "to.contain.class.array", %{
            expectedText: expected_text,
            isNot: is_not,
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    else
      if RegExp.reg_exp?(expected),
        do: raise(~s("expected" argument in toContainClass cannot be a RegExp value))

      ToMatchText.to_match_text(
        this,
        "toContainClass",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text = serialize_expected_text_values([expected])

          Locator._expect(locator, "to.contain.class", %{
            expectedText: expected_text,
            isNot: is_not,
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    end
  end

  def to_have_count(this, locator, expected, options \\ nil) do
    ToEqual.to_equal(
      this,
      "toHaveCount",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.have.count", %{
          expectedNumber: expected,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_css(this, locator, name, expected, options \\ nil) do
    ToMatchText.to_match_text(
      this,
      "toHaveCSS",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text = serialize_expected_text_values([expected])

        Locator._expect(locator, "to.have.css", %{
          expressionArg: name,
          expectedText: expected_text,
          isNot: is_not,
          pseudo: options[:pseudo],
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_id(this, locator, expected, options \\ nil) do
    ToMatchText.to_match_text(
      this,
      "toHaveId",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text = serialize_expected_text_values([expected])

        Locator._expect(locator, "to.have.id", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_js_property(this, locator, name, expected, options \\ nil) do
    ToEqual.to_equal(
      this,
      "toHaveJSProperty",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        Locator._expect(locator, "to.have.property", %{
          expressionArg: name,
          expectedValue: expected,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_role(this, locator, expected, options \\ nil) do
    if not is_binary(expected), do: raise(~s("role" argument in toHaveRole must be a string))

    ToMatchText.to_match_text(
      this,
      "toHaveRole",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text = serialize_expected_text_values([expected])

        Locator._expect(locator, "to.have.role", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_text(this, locator, expected, options \\ %{}) do
    options = options || %{}

    if is_list(expected) do
      ToEqual.to_equal(
        this,
        "toHaveText",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text =
            serialize_expected_text_values(expected, %{normalizeWhiteSpace: true, ignoreCase: options[:ignoreCase]})

          Locator._expect(locator, "to.have.text.array", %{
            expectedText: expected_text,
            isNot: is_not,
            useInnerText: options[:useInnerText],
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    else
      ToMatchText.to_match_text(
        this,
        "toHaveText",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text =
            serialize_expected_text_values([expected], %{normalizeWhiteSpace: true, ignoreCase: options[:ignoreCase]})

          Locator._expect(locator, "to.have.text", %{
            expectedText: expected_text,
            isNot: is_not,
            useInnerText: options[:useInnerText],
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    end
  end

  def to_have_value(this, locator, expected, options \\ nil) do
    ToMatchText.to_match_text(
      this,
      "toHaveValue",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text = serialize_expected_text_values([expected])

        Locator._expect(locator, "to.have.value", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_values(this, locator, expected, options \\ nil) do
    ToEqual.to_equal(
      this,
      "toHaveValues",
      locator,
      "Locator",
      fn is_not, timeout, signal ->
        expected_text = serialize_expected_text_values(expected)

        Locator._expect(locator, "to.have.values", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_title(this, page, expected, options \\ %{}) do
    ToMatchText.to_match_text(
      this,
      "toHaveTitle",
      page,
      "Page",
      fn is_not, timeout, signal ->
        expected_text = serialize_expected_text_values([expected], %{normalizeWhiteSpace: true})

        Frame._expect(Page.main_frame(page), "to.have.title", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options
    )
  end

  def to_have_url(this, page, expected, options \\ nil) do
    # if (isURLPattern(expected)) return toHaveURLWithPredicate(...);  -- not ported: URLPattern

    # Ports don't support predicates. Keep separate server and client codepaths
    if is_function(expected) do
      ToHaveURL.to_have_url_with_predicate(this, page, expected, options)
    else
      base_url = Heap.get(Page.context(page), :_options)[:baseURL]

      expected =
        if is_binary(expected), do: UrlMatch.construct_url_based_on_base_url(base_url, expected), else: expected

      ToMatchText.to_match_text(
        this,
        "toHaveURL",
        page,
        "Page",
        fn is_not, timeout, signal ->
          expected_text = serialize_expected_text_values([expected], %{ignoreCase: options[:ignoreCase]})

          Frame._expect(Page.main_frame(page), "to.have.url", %{
            expectedText: expected_text,
            isNot: is_not,
            timeout: timeout,
            signal: signal,
            title: this.title
          })
        end,
        expected,
        options
      )
    end
  end

  def to_be_ok(this, response) do
    matcher_name = "toBeOK"
    MatcherHint.expect_types(response, ["APIResponse"], matcher_name)

    content_type = APIResponse.headers(response)["content-type"]
    is_text_encoding = content_type && MimeType.is_textual_mime_type(content_type)

    [log, text] =
      if !!this.isNot == APIResponse.ok(response) do
        Promise.await(
          Promise.all([
            Promise.async(fn -> APIResponse._fetch_log(response) end),
            Promise.async(fn -> if is_text_encoding, do: APIResponse.text(response), else: :null end)
          ])
        )
      else
        [nil, nil]
      end

    message = fn ->
      MatcherHint.format_matcher_message(this.utils, %{
        isNot: this.isNot,
        promise: this.promise,
        matcherName: matcher_name,
        receiver: "response",
        expectation: "",
        log: log
      }) <>
        if text == :null,
          do: "",
          else: "\nResponse text:\n#{this.utils.dim_color(String.slice(text || "", 0, 1000))}"
    end

    pass = APIResponse.ok(response)
    %{message: message, pass: pass}
  end

  # toPass  -- not ported: test runner (expectConfig().testInfo, toPass config)
  # computeMatcherTitleSuffix  -- not ported: test steps (no testInfo; toHaveScreenshot)
  # deadlineForMatcher  -- not ported: toPass, expect.poll
end
