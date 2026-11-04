# upstream: packages/playwright/src/matchers/matchers.ts (subset)
# JS matchers are called with `this` = matcher state; here it is the first argument.
defmodule PlaywrightJS.Matchers.Matchers do
  alias PlaywrightJS.Client.{Frame, Locator, Page}
  alias PlaywrightJS.Isomorphic.{StringUtils, UrlMatch}
  alias PlaywrightJS.Matchers.{ToBeTruthy, ToMatchText}
  import PlaywrightJS.Runtime.Heap, only: [get: 2]

  # upstream: matchers.ts:57
  defp serialize_expected_text_values(items, options) do
    Enum.map(items, fn i ->
      %{
        string: if(StringUtils.is_string(i), do: i),
        regexSource: if(is_struct(i, Regex), do: Regex.source(i)),
        regexFlags: if(is_struct(i, Regex), do: StringUtils.regex_flags(i)),
        matchSubstring: options[:matchSubstring],
        ignoreCase: options[:ignoreCase],
        normalizeWhiteSpace: options[:normalizeWhiteSpace]
      }
    end)
  end

  # upstream: matchers.ts:94
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
      options || %{}
    )
  end

  # upstream: matchers.ts:393
  def to_have_text(this, locator, expected, options \\ %{}) do
    if is_list(expected) do
      raise "toHaveText with an array: not ported (toEqual.ts)"
    else
      ToMatchText.to_match_text(
        this,
        "toHaveText",
        locator,
        "Locator",
        fn is_not, timeout, signal ->
          expected_text = serialize_expected_text_values([expected], %{normalizeWhiteSpace: true, ignoreCase: options[:ignoreCase]})

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

  # upstream: matchers.ts:436
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

  # upstream: matchers.ts:448
  def to_have_url(this, page, expected, options \\ nil) do
    # if (isURLPattern(expected)) ...; if (typeof expected === 'function') ...  -- not ported: toHaveURL.ts
    if is_function(expected), do: raise("toHaveURL with a predicate: not ported (toHaveURL.ts)")

    base_url = get(Page.context(page), :_options)[:baseURL]
    expected = if is_binary(expected), do: UrlMatch.construct_url_based_on_base_url(base_url, expected), else: expected

    ToMatchText.to_match_text(
      this,
      "toHaveURL",
      page,
      "Page",
      fn is_not, timeout, signal ->
        expected_text = serialize_expected_text_values([expected], %{ignoreCase: (options || %{})[:ignoreCase]})

        Frame._expect(Page.main_frame(page), "to.have.url", %{
          expectedText: expected_text,
          isNot: is_not,
          timeout: timeout,
          signal: signal,
          title: this.title
        })
      end,
      expected,
      options || %{}
    )
  end
end
