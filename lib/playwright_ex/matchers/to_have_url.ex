defmodule PlaywrightEx.Matchers.ToHaveURL do
  @upstream "packages/playwright/src/matchers/toHaveURL.ts"
  @moduledoc """
  Port of `#{@upstream}`. The predicate gets the URL string (as `UrlMatch` matchers do).
  """

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.AbortSignal
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Matchers.MatcherHint
  alias PlaywrightEx.Runtime.Heap

  def to_have_url_with_predicate(this, page, expected, options \\ nil) do
    matcher_name = "toHaveURL"
    timeout = if options[:timeout] == nil, do: this.timeout, else: options.timeout
    base_url = Heap.get(Page.context(page), :_options)[:baseURL]
    local_utils = Connection.local_utils(Heap.get(page, :_connection))
    # `let lastCheckedURLString`, assigned in the predicate (which runs in this process).
    last_checked = Heap.new_object(PlaywrightEx.Client.Connect.Cell)

    try do
      Frame.wait_for_url(
        Page.main_frame(page),
        fn url ->
          last_checked_url_string = Heap.put(last_checked, :value, url)

          if options[:ignoreCase] do
            # The LocalUtils comes first: globs become regexes through the driver (UrlMatch).
            !this.isNot ==
              UrlMatch.url_matches(
                local_utils,
                base_url && String.downcase(base_url),
                String.downcase(last_checked_url_string),
                expected
              )
          else
            # The LocalUtils comes first: globs become regexes through the driver (UrlMatch).
            !this.isNot == UrlMatch.url_matches(local_utils, base_url, last_checked_url_string, expected)
          end
        end,
        %{timeout: timeout, signal: options[:signal]}
      )

      %{name: matcher_name, pass: !this.isNot, message: fn -> "" end}
    rescue
      e ->
        last_checked_url_string = Heap.get(last_checked, :value)

        if Map.get(e, :name) == "AbortError" do
          %{
            name: matcher_name,
            pass: this.isNot,
            message: fn ->
              MatcherHint.format_matcher_message(this.utils, %{
                isNot: this.isNot,
                promise: this.promise,
                matcherName: matcher_name,
                expectation: "expected",
                timeout: timeout,
                printedExpected: "Expected: predicate to #{if !this.isNot, do: "succeed", else: "fail"}",
                errorMessage: "Error: " <> AbortSignal.assertion_aborted_message(Map.get(e, :cause))
              })
            end,
            actual: last_checked_url_string,
            timeout: timeout
          }
        else
          %{
            name: matcher_name,
            pass: this.isNot,
            message: fn ->
              to_have_url_message(this, matcher_name, expected, last_checked_url_string, this.isNot, true, timeout)
            end,
            actual: last_checked_url_string,
            timeout: timeout
          }
        end
    end
  end

  defp to_have_url_message(state, matcher_name, expected, received, pass, timed_out, timeout) do
    received_string = received || ""

    {printed_expected, printed_received, printed_diff} =
      cond do
        is_function(expected) ->
          {"Expected: predicate to #{if !state.isNot, do: "succeed", else: "fail"}",
           "Received: #{state.utils.print_received(received_string)}", nil}

        pass ->
          formatted_received =
            MatcherHint.print_received_string_contain_expected_result(state.utils, received_string, nil)

          {"Expected pattern: not #{state.utils.print_expected(expected)}", "Received string: #{formatted_received}",
           nil}

        true ->
          label_expected = "Expected #{if is_binary(expected), do: "string", else: "pattern"}"

          {nil, nil,
           state.utils.print_diff_or_stringify(expected, received_string, label_expected, "Received string", false)}
      end

    MatcherHint.format_matcher_message(state.utils, %{
      isNot: state.isNot,
      promise: state.promise,
      matcherName: matcher_name,
      expectation: "expected",
      timeout: timeout,
      timedOut: timed_out,
      printedExpected: printed_expected,
      printedReceived: printed_received,
      printedDiff: printed_diff
    })
  end
end
