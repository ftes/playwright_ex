defmodule PlaywrightEx.Matchers.ToMatchAriaSnapshot do
  @upstream "packages/playwright/src/matchers/toMatchAriaSnapshot.ts"
  @moduledoc """
  Port of `#{@upstream}`: inline aria snapshots (`expected` is a string). File snapshots
  (`{ name, path }`, resolved by the test runner's `testInfo`) are not ported (PLAN, Decisions).
  """

  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Matchers.Expect
  alias PlaywrightEx.Matchers.MatcherHint

  @k_impossible_aria_match ~s(- none "Generating new baseline")

  def to_match_aria_snapshot(this, receiver, expected_param \\ nil, options \\ %{}) do
    options = options || %{}
    matcher_name = "toMatchAriaSnapshot"
    MatcherHint.expect_types(receiver, ["Page", "Locator"], matcher_name)
    locator = if is_struct(receiver, PlaywrightEx.Locator), do: receiver

    # const testInfo = expectConfig().testInfo; if (!testInfo) throw ...  -- not ported: no test runner (inline snapshots only)

    if Expect.expect_config()[:ignoreSnapshots] do
      %{pass: !this.isNot, message: fn -> "" end, name: "toMatchAriaSnapshot", expected: ""}
    else
      update_snapshots = Expect.expect_config()[:updateSnapshots]

      # let expectedPath: string | undefined;  -- not ported: file snapshots (testInfo)
      {expected, timeout} =
        if is_binary(expected_param) do
          {expected_param, if(options[:timeout] == nil, do: this.timeout, else: options.timeout)}
        else
          # const legacyPath = testInfo._resolveSnapshotPaths(...); ...  -- not ported: file snapshots (testInfo)
          raise "#{matcher_name}: file snapshots are not supported, pass the expected snapshot as a string"
        end

      is_missing_baseline = update_snapshots in ["missing", "default"] and expected == ""

      if is_missing_baseline and this.isNot do
        message = ~s(Matchers using ".not" can't generate new baselines)
        %{pass: this.isNot, message: fn -> message end, name: "toMatchAriaSnapshot"}
      else
        generate_baseline = !this.isNot and (update_snapshots == "all" or is_missing_baseline)
        # When generating new baseline, run entire pipeline against impossible match.
        expected = if generate_baseline, do: @k_impossible_aria_match, else: expected

        expected = unshift(expected)

        global_children = Expect.expect_config()[:toMatchAriaSnapshot][:children]

        expected =
          if global_children && !Regex.match?(~r/^- \/children:/m, expected),
            do: "- /children: #{global_children}\n" <> expected,
            else: expected

        expect_params = %{
          expectedValue: expected,
          isNot: this.isNot,
          timeout: timeout,
          signal: options[:signal],
          title: this.title
        }

        %{matches: pass} =
          result =
          if locator,
            do: Locator._expect(locator, "to.match.aria", expect_params),
            else: Frame._expect(Page.main_frame(receiver), "to.match.aria", expect_params)

        %{received: received, log: log, timedOut: timed_out, errorMessage: error_message} =
          Map.merge(%{log: nil, timedOut: nil, received: nil, errorMessage: nil}, result)

        typed_received = received[:value]

        message = fn ->
          {printed_expected, printed_received, printed_diff} =
            cond do
              error_message ->
                {"Expected: #{if this.isNot, do: "not ", else: ""}#{this.utils.print_expected(expected)}", nil, nil}

              pass ->
                received_string =
                  MatcherHint.print_received_string_contain_expected_substring(
                    this.utils,
                    typed_received["raw"],
                    index_of(typed_received["raw"], expected),
                    String.length(expected)
                  )

                {"Expected: not #{this.utils.print_expected(expected)}", "Received: #{received_string}", nil}

              true ->
                {nil, nil,
                 this.utils.print_diff_or_stringify(expected, typed_received["raw"], "Expected", "Received", false)}
            end

          MatcherHint.format_matcher_message(this.utils, %{
            isNot: this.isNot,
            promise: this.promise,
            matcherName: matcher_name,
            expectation: "expected",
            locator: locator && Locator.to_string(locator),
            timeout: timeout,
            timedOut: timed_out,
            printedExpected: printed_expected,
            printedReceived: printed_received,
            printedDiff: printed_diff,
            errorMessage: error_message,
            log: log
          })
        end

        cond do
          error_message ->
            %{pass: this.isNot, message: message, name: "toMatchAriaSnapshot", expected: expected}

          !this.isNot and (generate_baseline or (update_snapshots == "changed" and pass == this.isNot)) ->
            # if (expectedPath) { ...write the snapshot file... }  -- not ported: file snapshots (testInfo)
            suggested_rebaseline =
              "`\n#{StringUtils.escape_template_string(indent(typed_received["regex"], "{indent}  "))}\n{indent}`"

            if is_missing_baseline and update_snapshots == "default" do
              message = "A snapshot is not provided, generating new baseline."

              %{
                pass: true,
                message: fn -> "" end,
                name: "toMatchAriaSnapshot",
                suggestedRebaseline: suggested_rebaseline,
                softError: %RuntimeError{message: message},
                shouldNotRetryTest: true
              }
            else
              %{
                pass: true,
                message: fn -> "" end,
                name: "toMatchAriaSnapshot",
                suggestedRebaseline: suggested_rebaseline
              }
            end

          true ->
            %{
              name: matcher_name,
              expected: expected,
              message: message,
              pass: pass,
              actual: typed_received["raw"],
              log: log,
              timeout: if(timed_out, do: timeout)
            }
        end
      end
    end
  end

  defp unshift(snapshot) do
    lines = String.split(snapshot, "\n")

    whitespace_prefix_length =
      Enum.reduce(lines, 100, fn line, acc ->
        if String.trim(line) == "" do
          acc
        else
          [prefix] = Regex.run(~r/^(\s*)/, line, capture: :all_but_first)
          min(String.length(prefix), acc)
        end
      end)

    lines
    |> Enum.filter(&(String.trim(&1) != ""))
    |> Enum.map_join("\n", &String.slice(&1, whitespace_prefix_length..-1//1))
  end

  defp indent(snapshot, indent) do
    snapshot |> String.split("\n") |> Enum.map_join("\n", &(indent <> &1))
  end

  # `string.indexOf(search)` in characters, -1 when absent.
  defp index_of(_string, ""), do: 0

  defp index_of(string, search) do
    case :binary.match(string, search) do
      {byte, _} -> String.length(binary_part(string, 0, byte))
      :nomatch -> -1
    end
  end
end
