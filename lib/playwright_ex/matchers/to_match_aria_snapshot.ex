defmodule PlaywrightEx.Matchers.ToMatchAriaSnapshot do
  @upstream "packages/playwright/src/matchers/toMatchAriaSnapshot.ts"
  @moduledoc """
  Port of `#{@upstream}`: `expected` is a string (inline), or nil with the options as
  `expectedParam`'s object form (`name`, which `testInfo`, the running `PlaywrightEx.Test` test,
  resolves).

  Deviations (architecture: Generated facade): the `path` option is the snapshot file in place of
  a `name`, also outside a test. `updateSnapshots` comes from the expect configuration
  (`PlaywrightEx.Matchers.Expect`). A returned `suggestedRebaseline` fails the matcher with it
  (`PlaywrightEx.Matchers.Expect`).
  """

  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.Locator
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.StringUtils
  alias PlaywrightEx.Matchers.Expect
  alias PlaywrightEx.Matchers.MatcherHint
  alias PlaywrightEx.Test.TestInfo

  @k_impossible_aria_match ~s(- none "Generating new baseline")

  def to_match_aria_snapshot(this, receiver, expected_param \\ nil, options \\ %{}) do
    options = options || %{}
    matcher_name = "toMatchAriaSnapshot"
    MatcherHint.expect_types(receiver, ["Page", "Locator"], matcher_name)
    locator = if is_struct(receiver, PlaywrightEx.Locator), do: receiver

    test_info = Expect.expect_config().testInfo

    # deviation: upstream throws "toMatchAriaSnapshot() must be called during the test" without
    # `testInfo`; an inline snapshot or the path option works outside a test.

    if Expect.expect_config()[:ignoreSnapshots] do
      %{pass: !this.isNot, message: fn -> "" end, name: "toMatchAriaSnapshot", expected: ""}
    else
      update_snapshots = Expect.expect_config()[:updateSnapshots]

      # `expectedParam`'s object form is the options map, with `name` or (deviation) `path`.
      {name, options} = Map.pop(options, :name)
      {expected_path, options} = Map.pop(options, :path)
      timeout = if options[:timeout] == nil, do: this.timeout, else: options.timeout

      if expected_param != nil and expected_path,
        do: raise("#{matcher_name}() takes the expected snapshot or the path option, not both")

      if expected_param != nil and name,
        do: raise("#{matcher_name}() takes the expected snapshot or the name option, not both")

      if name && expected_path, do: raise("#{matcher_name}() takes the name or the path option, not both")

      if !is_binary(expected_param) and !is_binary(expected_path) and !(test_info && expected_param == nil),
        do: raise("#{matcher_name}() requires the expected snapshot or the path option")

      expected_path =
        cond do
          is_binary(expected_param) ->
            nil

          # deviation: the path option is the snapshot file.
          expected_path ->
            Path.expand(expected_path)

          true ->
            legacy_path =
              TestInfo._resolve_snapshot_paths(test_info, "aria", name, "dontUpdateSnapshotIndex", ".yml").absoluteSnapshotPath

            expected_path =
              TestInfo._resolve_snapshot_paths(test_info, "aria", name, "updateSnapshotIndex").absoluteSnapshotPath

            # in 1.51, we changed the default template to use .aria.yml extension
            # for backwards compatibility, we check for the legacy .yml extension
            if !File.exists?(expected_path) and File.exists?(legacy_path), do: legacy_path, else: expected_path
        end

      expected =
        if is_binary(expected_param) do
          expected_param
        else
          case File.read(expected_path) do
            {:ok, snapshot} -> snapshot
            {:error, _reason} -> ""
          end
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

        rebaseline = !this.isNot and (generate_baseline or (update_snapshots == "changed" and pass == this.isNot))

        cond do
          error_message ->
            %{pass: this.isNot, message: message, name: "toMatchAriaSnapshot", expected: expected}

          rebaseline and expected_path ->
            write_snapshot(expected_path, typed_received["regex"], is_missing_baseline, update_snapshots)

          rebaseline ->
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

  defp write_snapshot(expected_path, snapshot, is_missing_baseline, update_snapshots) do
    File.mkdir_p!(Path.dirname(expected_path))
    File.write!(expected_path, snapshot)
    relative_path = Path.relative_to_cwd(expected_path)
    passed = %{pass: true, message: fn -> "" end, name: "toMatchAriaSnapshot"}

    cond do
      is_missing_baseline and update_snapshots == "default" ->
        message = "A snapshot doesn't exist at #{relative_path}, writing actual."
        Map.merge(passed, %{softError: %RuntimeError{message: message}, shouldNotRetryTest: true})

      is_missing_baseline ->
        IO.puts("A snapshot doesn't exist at #{relative_path}, writing actual.")
        passed

      true ->
        IO.puts("A snapshot is generated at #{relative_path}.")
        passed
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
