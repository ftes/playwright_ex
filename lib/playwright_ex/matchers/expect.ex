defmodule PlaywrightEx.Matchers.Expect do
  @upstream "packages/playwright/src/matchers/expect.ts"
  @moduledoc """
  Port of `#{@upstream}`: how a matcher is called. The generated `PlaywrightEx.Expect` is
  `createMatchers`: one function per web-first matcher (`to_have_text`), and one with
  `isNot` set (`not_to_have_text`, Python's name for `expect(x).not.toHaveText`). Each calls
  `create_matcher/4` with the matcher of `custom_async_matchers/0`.

  A matcher gets the matcher state `this` (`ExpectMatcherStateInternal`): a map with `isNot`,
  `promise`, `utils` (`PlaywrightEx.Matchers.MatcherUtils`), `timeout` and `title`. It returns a
  `MatcherResult` map; a failed one raises `PlaywrightEx.ExpectError`.

  Deviations: there is no test runner (`testInfo` is `null`, so no steps, soft assertions or
  test deadlines) and no jest library: generic matchers (`toBe`, `toEqual`, ...), `expect.poll`,
  `expect.extend`, `toPass`, `toMatchSnapshot` and `resolves`/`rejects` are not ported.

  ## Configuration

  The `expect` part of upstream's `playwright.config.ts`, read when a matcher runs:

      config :playwright_ex, :expect, timeout: 10_000, update_snapshots: :missing

    * `:timeout` - Default timeout of the matchers in milliseconds, `0` or `:infinity` for no
      timeout. Defaults to `5000`. A `timeout:` option of a matcher wins.
    * `:update_snapshots` - When `to_have_screenshot` and `to_match_aria_snapshot` write snapshots:
      `:all`, `:changed`, `:missing`, `:none` or `:default` (the default: write missing ones).
      A screenshot is written to its `path`. An inline aria snapshot can't be written into the
      test source without a test runner, so where upstream suggests a rebaseline (an empty
      snapshot, or any under `:all` or a mismatch under `:changed`) the matcher fails with the
      new snapshot in its message.
    * `:ignore_snapshots` - Skip the snapshot matchers. Defaults to `false`.
    * `:to_have_screenshot`, `:to_match_aria_snapshot` - Defaults for their options, maps with
      the JS keys (`%{maxDiffPixels: 10}`, `%{children: "equal"}`), as upstream's config.
  """

  alias PlaywrightEx.ExpectError
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Matchers.MatcherUtils
  alias PlaywrightEx.Matchers.Matchers
  alias PlaywrightEx.Matchers.ToMatchAriaSnapshot
  alias PlaywrightEx.Matchers.ToMatchSnapshot

  # unfilteredStackTrace  -- not ported: Elixir stack traces

  # `_expectConfig` is module state, shared by every connection as in JS. Its initial value comes
  # from the app env (the test runner's config in JS, see the moduledoc).
  @default_expect_config %{testInfo: nil, ignoreSnapshots: false, updateSnapshots: "default"}

  @doc false
  def set_expect_config(config) do
    :persistent_term.put({__MODULE__, :expect_config}, config)
  end

  @doc false
  def expect_config do
    :persistent_term.get({__MODULE__, :expect_config}, nil) ||
      app_env_expect_config(Application.get_env(:playwright_ex, :expect, []))
  end

  # Elixir only: `config :playwright_ex, :expect, ...` as an `ExpectConfig`.
  @doc false
  def app_env_expect_config(env) do
    config = %{
      timeout: if(env[:timeout] == :infinity, do: 0, else: env[:timeout]),
      updateSnapshots: if(env[:update_snapshots] != nil, do: to_string(env[:update_snapshots])),
      ignoreSnapshots: env[:ignore_snapshots],
      toHaveScreenshot: env[:to_have_screenshot],
      toMatchAriaSnapshot: env[:to_match_aria_snapshot]
    }

    Map.merge(@default_expect_config, Map.reject(config, fn {_key, value} -> value == nil end))
  end

  @default_expect_timeout 5000

  # throwUnsupportedExpectMatcherError  -- not ported: custom matchers (expect.extend)

  @doc false
  # `customAsyncMatchers`, by JS name. `toPass` is not ported.
  def custom_async_matchers do
    %{
      "toBeAttached" => &Matchers.to_be_attached/3,
      "toBeChecked" => &Matchers.to_be_checked/3,
      "toBeDisabled" => &Matchers.to_be_disabled/3,
      "toBeEditable" => &Matchers.to_be_editable/3,
      "toBeEmpty" => &Matchers.to_be_empty/3,
      "toBeEnabled" => &Matchers.to_be_enabled/3,
      "toBeFocused" => &Matchers.to_be_focused/3,
      "toBeHidden" => &Matchers.to_be_hidden/3,
      "toBeInViewport" => &Matchers.to_be_in_viewport/3,
      "toBeOK" => &Matchers.to_be_ok/2,
      "toBeVisible" => &Matchers.to_be_visible/3,
      "toContainText" => &Matchers.to_contain_text/4,
      "toContainClass" => &Matchers.to_contain_class/4,
      "toHaveAccessibleDescription" => &Matchers.to_have_accessible_description/4,
      "toHaveAccessibleName" => &Matchers.to_have_accessible_name/4,
      "toHaveAccessibleErrorMessage" => &Matchers.to_have_accessible_error_message/4,
      "toHaveAttribute" => &Matchers.to_have_attribute/5,
      "toHaveClass" => &Matchers.to_have_class/4,
      "toHaveCount" => &Matchers.to_have_count/4,
      "toHaveCSS" => &Matchers.to_have_css/5,
      "toHaveId" => &Matchers.to_have_id/4,
      "toHaveJSProperty" => &Matchers.to_have_js_property/5,
      "toHaveRole" => &Matchers.to_have_role/4,
      "toHaveText" => &Matchers.to_have_text/4,
      "toHaveTitle" => &Matchers.to_have_title/4,
      "toHaveURL" => &Matchers.to_have_url/4,
      "toHaveValue" => &Matchers.to_have_value/4,
      "toHaveValues" => &Matchers.to_have_values/4,
      "toHaveScreenshot" => &ToMatchSnapshot.to_have_screenshot/3,
      "toMatchAriaSnapshot" => &ToMatchAriaSnapshot.to_match_aria_snapshot/4
    }
  end

  # allBuiltinMatchers, promiseThrowMatchers  -- not ported: jest generic assertions
  # createExpect  -- not ported: no expect function object (configure, soft, poll, extend)
  # createMatchers  -- ported as the generated PlaywrightEx.Expect (see the moduledoc)

  # Elixir has no rest parameters: the matcher function takes the argument list.
  def create_matcher(matcher_name, info, actual, matcher, promise \\ nil) do
    fn args -> call_matcher_as_step(matcher_name, info, actual, matcher, args, promise) end
  end

  def call_matcher_as_step(matcher_name, info, actual, matcher, args, promise \\ nil) do
    # const testInfo = expectConfig().testInfo;  -- not ported: no test runner
    custom_message = info[:message] || ""
    # const suffixes = computeMatcherTitleSuffix(matcherName, actual, args);  -- not ported: test steps
    default_title =
      "#{if info[:poll], do: "poll "}#{if info[:isSoft], do: "soft "}#{if info[:isNot], do: "not "}#{matcher_name}"

    title =
      if custom_message != "", do: custom_message, else: "Expect #{StringUtils.escape_with_quotes(default_title, "\"")}"

    # const stackFrames = expectConfig().filteredStackTrace(captureRawStack());  -- not ported: Elixir stack traces
    # const params = ...; const stepData = ...; const step = testInfo?._addStep(stepData);  -- not ported: test steps

    # handleError: no step, so the error is raised (soft assertions need a test runner).

    # validateMatcherResult(result);  -- not ported: built-in matchers only
    result = invoke_matcher(matcher_name, info, matcher, actual, args, promise, title)

    if result.pass == !!info[:isNot] do
      # Keys whose value is `undefined` are left out, so results compare with `==`.
      matcher_result =
        result
        |> Map.merge(%{name: matcher_name, message: get_message(result.message)})
        |> Map.reject(fn {_key, value} -> value == nil end)

      raise ExpectError.new(matcher_result, custom_message, nil)
    else
      # step?.complete(result);  -- not ported: test steps
      # deviation: no test runner writes a `suggestedRebaseline` into the test source (the
      # dispatcher's addSuggestedRebaseline), so a result that carries one fails with it, after
      # its `softError`. Otherwise an inline aria snapshot would pass without being compared.
      if result[:suggestedRebaseline] do
        message = suggested_rebaseline_message(result)

        matcher_result =
          result
          |> Map.merge(%{name: matcher_name, message: message})
          |> Map.reject(fn {_key, value} -> value == nil end)

        raise ExpectError.new(matcher_result, custom_message, nil)
      end

      :ok
    end
  end

  # Elixir only: the message of a `suggestedRebaseline` that is not written (see above). The
  # rebaseline is a JS template literal with `{indent}` placeholders; its body is printed.
  defp suggested_rebaseline_message(result) do
    rebaseline =
      result.suggestedRebaseline
      |> String.replace("{indent}", "")
      |> String.trim_leading("`\n")
      |> String.trim_trailing("\n`")

    soft_error = if result[:softError], do: Exception.message(result.softError) <> "\n"

    "#{soft_error}Inline snapshots are not updated without a test runner. New snapshot:\n\n#{rebaseline}"
  end

  # expectLibrary.ts getMessage
  defp get_message(message) when is_function(message, 0), do: message.()
  defp get_message(message), do: message

  defp invoke_matcher(_matcher_name, info, matcher, actual, args, promise, title) do
    is_not = !!info[:isNot]
    timeout = info[:timeout] || expect_config()[:timeout] || @default_expect_timeout

    matcher_context = %{
      customTesters: [],
      isNot: is_not,
      promise: promise || "",
      utils: MatcherUtils,
      timeout: timeout,
      title: title
      # equals: throwUnsupportedExpectMatcherError  -- not ported: custom matchers
    }

    # if (!promise) ...; resolves / rejects  -- not ported: jest generic assertions
    apply(matcher, [matcher_context, actual | args])
  end

  # invokePollMatcher  -- not ported: expect.poll (jest generic assertions)
  # mergeExpects  -- not ported: expect.extend
end
