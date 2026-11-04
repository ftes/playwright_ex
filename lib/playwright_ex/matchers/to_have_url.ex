defmodule PlaywrightEx.Matchers.ToHaveURL do
  @upstream "packages/playwright/src/matchers/toHaveURL.ts"
  @moduledoc """
  Port of `#{@upstream}`. The predicate gets the URL string (as `UrlMatch` matchers do).
  """

  alias PlaywrightEx.Client.Connection
  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Isomorphic.UrlMatch
  alias PlaywrightEx.Matchers.MatcherHint
  alias PlaywrightEx.Runtime.EventLoop
  alias PlaywrightEx.Runtime.Heap

  def to_have_url_with_predicate(this, page, expected, options \\ nil) do
    matcher_name = "toHaveURL"
    timeout = if options[:timeout] == nil, do: this.timeout, else: options.timeout
    base_url = Heap.get(Page.context(page), :_options)[:baseURL]
    local_utils = Connection.local_utils(Heap.get(page, :_connection))
    # `let lastCheckedURLString`, assigned in the predicate (which may run in a listener process).
    %EventLoop{heap: heap} = loop = EventLoop.current!()
    last_checked = %{guid: make_ref(), loop: loop, heap: heap}

    try do
      Frame.wait_for_url(
        Page.main_frame(page),
        fn url ->
          last_checked_url_string = Heap.put(last_checked, :value, url)

          if options[:ignoreCase] do
            !this.isNot ==
              UrlMatch.url_matches(
                local_utils,
                base_url && String.downcase(base_url),
                String.downcase(last_checked_url_string),
                expected
              )
          else
            !this.isNot == UrlMatch.url_matches(local_utils, base_url, last_checked_url_string, expected)
          end
        end,
        %{timeout: timeout}
      )

      %{name: matcher_name, pass: !this.isNot, message: fn -> "" end}
    rescue
      _e ->
        # if (e instanceof Error && e.name === 'AbortError') return { ... };  -- not ported: AbortSignal
        last_checked_url_string = Heap.get(last_checked, :value)

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
