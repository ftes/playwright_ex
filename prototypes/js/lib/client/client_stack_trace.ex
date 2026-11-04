# upstream: packages/playwright-core/src/client/clientStackTrace.ts
defmodule PlaywrightJS.Client.ClientStackTrace do
  # upstream: clientStackTrace.ts:21
  def capture_library_stack_trace do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    parsed_frames =
      Enum.map(stack, fn {module, function, arity, location} ->
        frame = %{file: to_string(location[:file] || ""), line: location[:line] || 0, column: 0, function: {module, function, arity}}

        is_playwright_library =
          String.starts_with?(Atom.to_string(module), [
            "Elixir.PlaywrightJS.Client.",
            "Elixir.PlaywrightJS.Isomorphic.",
            "Elixir.PlaywrightJS.Protocol."
          ])

        %{frame: frame, isPlaywrightLibrary: is_playwright_library}
      end)

    # Deepest transition between non-client code calling into client code is the api entry.
    # (BEAM drops tail-call frames, so the entry point recorded by `Api.def` wins.)
    api_name =
      PlaywrightJS.Runtime.Zones.data(:apiName) ||
        parsed_frames
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find_value("", fn [parsed_frame, next] ->
          if parsed_frame.isPlaywrightLibrary and !next.isPlaywrightLibrary, do: normalize_api_name(parsed_frame.frame.function)
        end)

    # This is for the inspector so that it did not include the test runner stack frames.
    parsed_frames = Enum.reject(parsed_frames, & &1.isPlaywrightLibrary)

    %{frames: Enum.map(parsed_frames, & &1.frame), apiName: api_name}
  end

  # upstream: clientStackTrace.ts:55
  # {PlaywrightJS.Client.Page, :"-wait_for_event/3-fun-0-", 1} -> "page.waitForEvent"
  defp normalize_api_name({module, function, _arity}) do
    [class | _] = module |> Module.split() |> Enum.reverse()
    function = Atom.to_string(function)

    function =
      case Regex.run(~r/^-(.+)\/\d+-/, function) do
        [_, name] -> name
        nil -> function
      end

    String.downcase(String.first(class)) <> String.slice(class, 1..-1//1) <> "." <> camelize(function)
  end

  defp camelize("_" <> rest), do: "_" <> camelize(rest)
  defp camelize(function), do: function |> String.split("_") |> then(fn [h | t] -> h <> Enum.map_join(t, &String.capitalize/1) end)
end
