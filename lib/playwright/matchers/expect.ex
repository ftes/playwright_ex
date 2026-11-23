# Copyright Microsoft Corporation. All rights reserved.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Matchers.Expect do
  @upstream "packages/playwright/src/matchers/expect.ts"
  @config_doc """
  Upstream's `playwright.config.ts` is `config :playwright, :test` (see "Config" in
  `Playwright.Test`); the matchers read its `expect` block and its `update_snapshots` and
  `ignore_snapshots` keys, also without `Playwright.Test`, when a matcher runs (so an
  `Application.put_env/3` in `test_helper.exs` applies too):

      config :playwright, :test,
        expect: [timeout: 10_000, to_have_screenshot: [max_diff_pixels: 10]],
        update_snapshots: :missing

  `expect`'s keys:

    * `:timeout` - Default timeout of the matchers in milliseconds. Defaults to `5000`. A
      `timeout:` option of a matcher wins. `:infinity` is no limit, and so is `0`, as in
      Playwright: `0` never means "fail at once" (see [API conventions](api-conventions.md)).
    * `:to_pass` - Defaults of `Playwright.Expect.to_pass/2`'s options, `[timeout: 10_000,
      intervals: [1000]]`. Its timeout defaults to `0`, no limit of its own (the test's timeout
      bounds it), not `:timeout`; `:infinity` is `0`.
    * `:to_have_screenshot` - Defaults of `Playwright.Expect.to_have_screenshot/2`'s options, as
      it names them: `:animations`, `:caret`, `:max_diff_pixels`, `:max_diff_pixel_ratio`,
      `:scale`, `:style_path`, `:threshold` and `:timeout` (over the expect `:timeout`, under a
      call's), as in `[max_diff_pixels: 10]`, and the config's own `:type` (`:png` or `:webp`, of
      an unnamed snapshot) and `:path_template` (see "Snapshots" in `Playwright.Test`).
    * `:to_match_aria_snapshot` - `:children` (`:contain`, `:equal` or `:deep_equal`: the
      `/children` mode of a snapshot that sets none) and `:path_template`.

  The snapshot keys:

    * `:update_snapshots` - When `to_have_screenshot` and `to_match_aria_snapshot` write snapshots:
      `:all`, `:changed`, `:missing`, `:none` or `:default` (the default: write missing ones,
      which fails a `Playwright.Test` test at its end, as upstream's). A snapshot is written to
      the file its `name:` resolves to in a `Playwright.Test` test, or to its `path:`. An
      inline aria snapshot is not written into the test source, so where upstream suggests a
      rebaseline (an empty snapshot, or any under `:all` or a mismatch under `:changed`) the
      matcher fails with the new snapshot in its message.
    * `:ignore_snapshots` - Skip the snapshot matchers. Defaults to `false`.

  The keys are upstream's config keys, snake_case; `expect` and each of its matchers take a
  keyword list or a map. Unknown keys raise `ArgumentError`, as do the values upstream checks
  (`update_snapshots`, `ignore_snapshots`, `to_have_screenshot`'s `type`) and those the matchers'
  options check, at application start for the config files.
  """
  @moduledoc """
  Port of `#{@upstream}`: how a matcher is called. The generated `Playwright.Expect` is
  `createMatchers`: one function per web-first matcher (`to_have_text`), and one with
  `isNot` set (`not_to_have_text`, Python's name for `expect(x).not.toHaveText`). Each calls
  `create_matcher/4` with the matcher of `custom_async_matchers/0`, and the info of its
  receiver: `isNot` of `Playwright.Expect.not_/1`, `isSoft` of `Playwright.Expect.soft/1`
  (`expect.soft`), `message` of `Playwright.Expect.message/2` (`expect(actual, message)`).

  A matcher gets the matcher state `this` (`ExpectMatcherStateInternal`): a map with `isNot`,
  `promise`, `utils` (`Playwright.Matchers.MatcherUtils`), `timeout` and `title`. It returns a
  `MatcherResult` map; a failed one raises `Playwright.ExpectError`. A matcher call returns the
  result's `value`: `toPass`'s passing attempt, `nil` otherwise.

  Deviations: `testInfo` is the running test of `Playwright.Test` (`Playwright.Test.TestInfo`,
  found by the calling process, or one in its `$callers`), else `null`. Each matcher call is a
  step of it (`category: 'expect'`), which records a result's `softError`: that fails the test
  at the end of its body; outside a test it is printed. A failed soft matcher in a test
  completes its step with the error as its `softError` and returns. There is no `createExpect`
  (`expect.configure`), and no jest library: generic matchers (`toBe`, `toEqual`, ...),
  `expect.extend`, `toMatchSnapshot` and `resolves`/`rejects` are not ported. So
  `expect.poll(actual, options)` has one matcher, `assert`: an ExUnit assertion,
  `fn value -> assert value == 3 end` for `.toBe(3)` (`poll/3`).

  ## Configuration

  #{@config_doc}
  """

  @doc false
  # The configuration section, also rendered in the generated `Playwright.Expect` (`ApiRules`).
  def __config_doc__, do: @config_doc

  alias Playwright.Client.ClientHelper
  alias Playwright.ExpectError
  alias Playwright.Isomorphic.StringUtils
  alias Playwright.Isomorphic.TimeoutRunner
  alias Playwright.Matchers.MatcherUtils
  alias Playwright.Matchers.Matchers
  alias Playwright.Matchers.ToMatchAriaSnapshot
  alias Playwright.Matchers.ToMatchSnapshot
  alias Playwright.Runtime.Zones
  alias Playwright.Test.TestInfo

  # unfilteredStackTrace  -- not ported: Elixir stack traces

  # `_expectConfig` is module state, shared by every connection as in JS. Its initial value comes
  # from the app env (the test runner's config, as in JS, see the moduledoc).
  @default_expect_config %{testInfo: nil, ignoreSnapshots: false, updateSnapshots: "default"}

  @doc false
  def set_expect_config(config) do
    :persistent_term.put({__MODULE__, :expect_config}, config)
  end

  @doc false
  def expect_config, do: expect_config(:call)

  @doc false
  # deviation: the worker sets `testInfo` per test (`setExpectConfig`); here it is the running
  # `Playwright.Test` test of the calling process, or of one in its `$callers`: in a matcher
  # call (`:call`), the one `call_matcher_as_step/6` found, else (`:now`) looked up.
  def expect_config(at) do
    config = :persistent_term.get({__MODULE__, :expect_config}, nil) || app_env_expect_config()
    if config[:testInfo] == nil, do: Map.put(config, :testInfo, current_test_info(at)), else: config
  end

  defp current_test_info(:call) do
    case Zones.data(:expectTestInfo) do
      {test_info} -> test_info
      nil -> TestInfo.current()
    end
  end

  defp current_test_info(:now), do: TestInfo.current()

  @doc false
  # Elixir only: the app env's `ExpectConfig`, of `config :playwright, :test`, built when its
  # matcher keys change (at application start, which so validates it, or after an
  # `Application.put_env/3` in a test helper). Cached by those keys' entries only, so a change
  # of the runner's keys alone keeps it (reordered matcher entries rebuild it); a `:test` that is
  # no keyword list is the key itself, so `app_env_expect_config/1` raises for it.
  def app_env_expect_config do
    env = Application.get_env(:playwright, :test, [])

    key =
      if is_list(env) and Keyword.keyword?(env),
        do: Keyword.take(env, Playwright.Test.Options.matcher_keys()),
        else: env

    case :persistent_term.get({__MODULE__, :app_env_expect_config}, nil) do
      {^key, config} ->
        config

      _ ->
        config = app_env_expect_config(env)
        :persistent_term.put({__MODULE__, :app_env_expect_config}, {key, config})
        config
    end
  end

  @config_label "config :playwright, :test"
  @expect_keys [:timeout, :to_have_screenshot, :to_match_aria_snapshot, :to_pass]
  @update_snapshots [:all, :changed, :missing, :none, :default]
  @update_snapshot_names Enum.map(@update_snapshots, &Atom.to_string/1)

  # Elixir only: `config :playwright, :test`'s `expect`, `update_snapshots` and
  # `ignore_snapshots` as an `ExpectConfig`, its keys and those of its matchers' options
  # snake_case, as the matchers take them. The other keys are `Playwright.Test.Options`'.
  # Its errors read as those of the other keys: `<label>: invalid value <value> for <key path>,
  # expected ...`, `<label>: unknown option <key path>, expected one of ...`.
  @doc false
  def app_env_expect_config(env) do
    env = Playwright.Application.keyword!(@config_label, env)
    expect = labeled!(fn -> expect!(env[:expect]) end)

    # Upstream's `validateConfig` (`updateSnapshots`) and `validateProject` (`ignoreSnapshots`).
    if !(env[:update_snapshots] in [nil | @update_snapshots] or env[:update_snapshots] in @update_snapshot_names),
      do:
        raise(
          ArgumentError,
          "#{@config_label}: invalid value #{inspect(env[:update_snapshots])} for update_snapshots, expected one of " <>
            Enum.map_join(@update_snapshots, ", ", &inspect/1)
        )

    if !(env[:ignore_snapshots] in [nil, true, false]),
      do:
        raise(
          ArgumentError,
          "#{@config_label}: invalid value #{inspect(env[:ignore_snapshots])} for ignore_snapshots, expected a boolean"
        )

    config = %{
      timeout: if(expect[:timeout] == :infinity, do: 0, else: expect[:timeout]),
      updateSnapshots: if(env[:update_snapshots] != nil, do: to_string(env[:update_snapshots])),
      ignoreSnapshots: env[:ignore_snapshots],
      toHaveScreenshot: matcher_config(expect, :to_have_screenshot),
      toMatchAriaSnapshot: matcher_config(expect, :to_match_aria_snapshot),
      toPass: matcher_config(expect, :to_pass)
    }

    Map.merge(@default_expect_config, Map.reject(config, fn {_key, value} -> value == nil end))
  end

  defp expect!(nil), do: []

  defp expect!(expect), do: Playwright.Test.Options.to_keyword!(:expect, expect, @expect_keys)

  # An `ArgumentError` of `fun` with the config's label.
  defp labeled!(fun) do
    fun.()
  rescue
    error in ArgumentError -> reraise ArgumentError, "#{@config_label}: " <> Exception.message(error), __STACKTRACE__
  end

  # Upstream's config keys of each matcher (`packages/playwright/types/test.d.ts`): options of the
  # matcher, which `Playwright.Expect`'s schema converts, and keys of the config only.
  @matcher_config %{
    to_have_screenshot:
      {[:animations, :caret, :max_diff_pixels, :max_diff_pixel_ratio, :scale, :style_path, :threshold, :timeout],
       [:type, :path_template]},
    to_match_aria_snapshot: {[], [:path_template, :children]},
    to_pass: {[:timeout, :intervals], []}
  }

  defp matcher_config(expect, key) do
    path = "expect.#{key}"
    {option_keys, config_keys} = Map.fetch!(@matcher_config, key)

    case expect[key] do
      nil ->
        nil

      options ->
        {options, config_only} =
          labeled!(fn ->
            options = Playwright.Test.Options.to_keyword!(path, options, option_keys ++ config_keys)
            {options, config_only} = Keyword.split(options, option_keys)
            {options, Map.new(config_only, fn {name, value} -> config_value!(path, name, value) end)}
          end)

        options
        |> Playwright.Runtime.Facade.options_at!(Playwright.Expect.__options_type__(key), @config_label, [:expect, key])
        |> Map.merge(config_only)
    end
  end

  # Only the screenshot's `type` is checked, as upstream's `validateProject`; the others pass
  # as given, an atom `children` as its wire string (`:deep_equal` is `"deep-equal"`).
  defp config_value!(_path, :path_template, template), do: {:pathTemplate, template}
  defp config_value!(_path, :type, type) when type in [:png, :webp, "png", "webp"], do: {:type, to_string(type)}

  defp config_value!(path, :type, type),
    do: raise(ArgumentError, "invalid value #{inspect(type)} for #{path}.type, expected one of :png, :webp")

  defp config_value!(_path, :children, children) when is_atom(children) and children != nil,
    do: {:children, children |> to_string() |> String.replace("_", "-")}

  defp config_value!(_path, :children, children), do: {:children, children}

  @default_expect_timeout 5000

  @doc false
  # Elixir only: the matchers' timeout of `config :playwright, :test, expect: [...]`, as `invoke_matcher`
  # resolves it for a receiver without one (`Playwright.Test.config/0`).
  def config_timeout, do: app_env_expect_config()[:timeout] || @default_expect_timeout

  # throwUnsupportedExpectMatcherError  -- not ported: custom matchers (expect.extend)

  @doc false
  # `customAsyncMatchers`, by JS name.
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
      "toMatchAriaSnapshot" => &ToMatchAriaSnapshot.to_match_aria_snapshot/4,
      "toPass" => &Matchers.to_pass/3
    }
  end

  # allBuiltinMatchers, promiseThrowMatchers  -- not ported: jest generic assertions
  # createExpect  -- not ported: no expect function object (configure, extend); its `soft` is the generated Playwright.Expect.soft/1, its `expectFn(actual, message)` Playwright.Expect.message/2, its `poll` poll/3
  # createMatchers  -- ported as the generated Playwright.Expect (see the moduledoc)

  @doc false
  # `expectFn.poll(actual, messageOrOptions)` of `createExpect(info)`, with `createMatchers`' message:
  # the matcher of the poll. Elixir only: its one matcher is `assert` (see the moduledoc), whose
  # argument is the assertion. JS's `expect.poll(fn).not` is an assertion that refutes.
  def poll(info, actual, message_or_options) do
    if info[:isNot],
      do: raise(ArgumentError, "expect.poll: a negated receiver; refute in the assertion instead")

    poll = if is_binary(message_or_options), do: %{}, else: message_or_options || %{}
    info = Map.put(info, :poll, %{timeout: poll[:timeout], intervals: poll[:intervals]})

    message =
      if is_binary(message_or_options),
        do: message_or_options,
        else: truthy_or(message_or_options[:message], info[:message])

    create_matcher("assert", Map.put(info, :message, message), actual, &assert_matcher/3)
  end

  # Elixir only: the `assert` matcher of `expect.poll`, a jest matcher's place (`toBe`): the
  # assertion raises when it fails.
  defp assert_matcher(_this, actual, assertion) do
    assertion.(actual)
    %{pass: true, message: fn -> "" end}
  end

  # JS `a || b`.
  defp truthy_or(a, b), do: if(ClientHelper.truthy(a), do: a, else: b)

  # Elixir has no rest parameters: the matcher function takes the argument list.
  def create_matcher(matcher_name, info, actual, matcher, promise \\ nil) do
    fn args -> call_matcher_as_step(matcher_name, info, actual, matcher, args, promise) end
  end

  def call_matcher_as_step(matcher_name, info, actual, matcher, args, promise \\ nil) do
    test_info = expect_config().testInfo
    custom_message = info[:message] || ""
    suffixes = Matchers.compute_matcher_title_suffix(matcher_name, actual, args)

    default_title =
      "#{if info[:poll], do: "poll "}#{if info[:isSoft], do: "soft "}#{if info[:isNot], do: "not "}#{matcher_name}#{suffixes[:titleSuffix] || ""}"

    title =
      if custom_message != "", do: custom_message, else: "Expect #{StringUtils.escape_with_quotes(default_title, "\"")}"

    # This looks like it is unnecessary, but it isn't - we need to filter
    # out all the frames that belong to the test runner from caught runtime errors.
    stack_frames = TestInfo.stack_frames(TestInfo.filtered_stack_trace(TestInfo.capture_raw_stack()))
    params = suffixes[:params] || %{}
    # Elixir only: the facade passes the options it got, `%{}` for none (JS `undefined`), and a
    # function (`toPass`'s callback, `poll`'s assertion) is no value to expect.
    params =
      if ClientHelper.truthy(Enum.at(args, 0)) and Enum.at(args, 0) != %{} and not is_function(Enum.at(args, 0)),
        do: Map.put(params, :expected, hd(args)),
        else: params

    step_data = %{
      category: "expect",
      title: title,
      subtitle: suffixes[:subtitle],
      stack: stack_frames,
      params: if(map_size(params) > 0, do: params)
    }

    step = if test_info, do: TestInfo._add_step(test_info, step_data)

    # `error` is `{kind, reason, stacktrace}`.
    handle_error = fn {kind, reason, stacktrace} = error, result ->
      if info[:isSoft] && step do
        TestInfo.step_complete(step, Map.merge(result || %{}, %{error: error, softError: error}))
      else
        if step, do: TestInfo.step_complete(step, Map.put(result || %{}, :error, error))
        :erlang.raise(kind, reason, stacktrace)
      end
    end

    finalizer = fn result ->
      # validateMatcherResult(result);  -- not ported: built-in matchers only
      if result.pass == !!info[:isNot] do
        # Keys whose value is `undefined` are left out, so results compare with `==`.
        matcher_result =
          result
          |> Map.merge(%{name: matcher_name, message: get_message(result.message)})
          |> Map.reject(fn {_key, value} -> value == nil end)

        error = ExpectError.new(matcher_result, custom_message, stack_frames)
        {:error, error, result}
      else
        # deviation: a `suggestedRebaseline` is not written into the test source (the
        # dispatcher's addSuggestedRebaseline), so a result that carries one fails with it, after
        # its `softError` (in its message). Otherwise an inline aria snapshot would pass without
        # being compared.
        if result[:suggestedRebaseline] do
          message = suggested_rebaseline_message(result)

          matcher_result =
            result
            |> Map.merge(%{name: matcher_name, message: message})
            |> Map.reject(fn {_key, value} -> value == nil end)

          {:error, ExpectError.new(matcher_result, custom_message, stack_frames), Map.delete(result, :softError)}
        else
          if step do
            TestInfo.step_complete(step, result)
          else
            # deviation: outside a `Playwright.Test` test nothing records a `softError`, so a
            # snapshot the matcher wrote is announced.
            if result[:softError], do: IO.puts(Exception.message(result.softError))
          end

          {:ok, result[:value]}
        end
      end
    end

    # deviation: the finalizer's error is raised here, with Elixir's stacktrace of the raise
    # (`stackFrames` are only the step's). It runs after the `try`, as a second `handleError` of
    # its error would do nothing. A soft error returns from `handleError`, so does the matcher.
    result =
      try do
        invoke = fn ->
          if info[:poll],
            do: invoke_poll_matcher(matcher_name, info, matcher, actual, args, promise),
            else: invoke_matcher(matcher_name, info, matcher, actual, args, promise, title)
        end

        # if (result instanceof Promise) return result.then(finalizer, handleError);  -- not ported: matchers return their result
        # Elixir only: the matcher's `expectConfig()` reads get this call's `testInfo`
        # (`expect_config/1`), not each a lookup.
        invoke = fn -> Zones.with(:expectTestInfo, {test_info}, invoke) end
        {:ok, if(step, do: Zones.with(:stepZone, step, invoke), else: invoke.())}
      catch
        kind, reason ->
          handle_error.({kind, reason, __STACKTRACE__}, nil)
          # A soft error: `handleError` returned.
          :soft
      end

    # Elixir only: the result's `value` (`toPass`'s passing attempt, `Matchers.to_pass/3`), `nil` for
    # the other matchers and a soft error.
    with {:ok, result} <- result,
         {:error, error, result} <- finalizer.(result) do
      try do
        raise error
      rescue
        error -> handle_error.({:error, error, __STACKTRACE__}, result)
      end

      nil
    else
      {:ok, value} -> value
      :soft -> nil
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

    "#{soft_error}Inline snapshots are not written into the test source. New snapshot:\n\n#{rebaseline}"
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

  defp invoke_poll_matcher(matcher_name, info, matcher, actual, args, promise) do
    if !is_function(actual, 0), do: raise("`expect.poll()` accepts only function as a first argument")

    if promise || custom_async_matchers()[matcher_name],
      do: raise("`expect.poll()` does not support \"#{promise || matcher_name}\" matcher.")

    test_info = expect_config().testInfo
    poll = info.poll
    timeout = poll[:timeout] || info[:timeout] || expect_config()[:timeout] || @default_expect_timeout
    %{deadline: deadline, timeoutMessage: timeout_message} = Matchers.deadline_for_matcher(test_info, timeout)

    result =
      TimeoutRunner.poll_against_deadline(
        fn ->
          # The running test, not the matcher call's: polling ends with the test's body.
          if test_info && expect_config(:now).testInfo != test_info do
            %{continuePolling: false, result: nil}
          else
            value = actual.()
            attempt_info = %{info | poll: nil, isSoft: false}

            # Elixir only: the `assert` matcher's attempt is no matcher step around its
            # assertion, whose own step (`Playwright.Test.Assertions.assert/1`, with its expression and
            # `expected`) is the attempt's, as upstream's attempt is `toEqual(expected)`'s; with
            # a message (the attempt's title) or `assert_steps: false` it is the matcher's.
            own_step? = matcher_name == "assert" and assert_steps?(test_info) and !ClientHelper.truthy(info[:message])

            try do
              if own_step?,
                do: invoke_matcher(matcher_name, attempt_info, matcher, value, args, nil, nil),
                else: call_matcher_as_step(matcher_name, attempt_info, value, matcher, args)

              %{continuePolling: false, result: nil}
            catch
              kind, reason ->
                # Elixir only: a failed `assert/1`'s step, as for a `to_pass` attempt
                # (`Playwright.Test.__assertion_error__/2`); another error's, the matcher's.
                error = {kind, reason, __STACKTRACE__}

                if own_step? and !Playwright.Test.__assertion_error__(test_info, error),
                  do: failed_attempt_step(attempt_info, value, args, error)

                %{continuePolling: true, result: error}
            end
          end
        end,
        deadline,
        poll[:intervals] || [100, 250, 500, 1000]
      )

    if result.timedOut do
      # Elixir only: the error's message without the blank lines an `ExUnit.AssertionError`'s starts with.
      message =
        if result.result,
          do:
            Enum.join(
              [String.trim_leading(TestInfo.error_message(result.result)), "", "Call Log:", "- #{timeout_message}"],
              "\n"
            ),
          else: timeout_message

      %{pass: !!info[:isNot], message: fn -> message end}
    else
      %{pass: !info[:isNot], message: fn -> "" end}
    end
  end

  # The matcher's step of a failed `assert` attempt, with its error (raised again, not run again).
  defp failed_attempt_step(info, value, args, {kind, reason, stacktrace}) do
    call_matcher_as_step(
      "assert",
      info,
      value,
      fn _this, _actual, _assertion -> :erlang.raise(kind, reason, stacktrace) end,
      args
    )
  catch
    _kind, _reason -> :ok
  end

  # Whether the test records its assertions as steps (`Playwright.Test`'s `assert_steps`).
  defp assert_steps?(test_info), do: Map.get(test_info || %{}, :assert_steps, true)

  # mergeExpects  -- not ported: expect.extend
end
