defmodule PlaywrightEx.Client.ClientStackTrace do
  @upstream "packages/playwright-core/src/client/clientStackTrace.ts"
  @moduledoc """
  Port of `#{@upstream}`. Library frames are those of `PlaywrightEx.*` modules other than
  `PlaywrightEx.Driver`, instead of files under the core dir.

  Deviations: the API name recorded by `PlaywrightEx.Runtime.Api.call/3` wins over the stack
  (BEAM drops tail-call frames). Upstream's `filterStackFile` drops internal frames; here
  every frame up to the outermost library frame is dropped (that includes
  `Process.info/2`), so the first frame is the caller's; in a handed-off listener process,
  the library frames it starts with don't count.
  """
  @library Enum.map(~w(Client Isomorphic Protocol Runtime Transport), &"Elixir.PlaywrightEx.#{&1}.")

  def capture_library_stack_trace do
    {:current_stacktrace, stack} = Process.info(self(), :current_stacktrace)

    parsed_frames =
      Enum.map(stack, fn {module, function, arity, location} ->
        frame = %{
          # JS stack frames carry absolute paths (metadata.location.file)
          file: if(file = location[:file], do: Path.expand(to_string(file)), else: ""),
          line: location[:line] || 0,
          column: 0,
          function: Exception.format_mfa(module, function, arity)
        }

        is_playwright_library =
          String.starts_with?(Atom.to_string(module), @library)

        %{frame: frame, mfa: {module, function, arity}, isPlaywrightLibrary: is_playwright_library}
      end)

    # Deepest transition between non-client code calling into client code is the api entry.
    # (BEAM drops tail-call frames, so the entry point recorded by `Runtime.Api.call/3` wins.)
    api_name =
      PlaywrightEx.Runtime.Zones.data(:apiName) ||
        parsed_frames
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.find_value("", fn [parsed_frame, next] ->
          if parsed_frame.isPlaywrightLibrary and !next.isPlaywrightLibrary,
            do: normalize_api_name(parsed_frame.mfa)
        end)

    # This is for the inspector so that it did not include the test runner stack frames.
    # (The library frames a listener or async process starts with (`PlaywrightEx.Runtime.Conn`)
    # are below the caller's: they don't count.)
    parsed_frames = parsed_frames |> Enum.reverse() |> Enum.drop_while(& &1.isPlaywrightLibrary) |> Enum.reverse()
    outermost = parsed_frames |> Enum.with_index() |> Enum.filter(&elem(&1, 0).isPlaywrightLibrary) |> List.last()

    parsed_frames =
      if outermost, do: Enum.drop(parsed_frames, elem(outermost, 1) + 1), else: Enum.drop(parsed_frames, 1)

    parsed_frames = Enum.reject(parsed_frames, &(&1.frame.file == ""))

    %{frames: Enum.map(parsed_frames, & &1.frame), apiName: api_name}
  end

  # {PlaywrightEx.Client.Page, :"-wait_for_event/3-fun-0-", 1} -> "page.waitForEvent"
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

  defp camelize(function),
    do: function |> String.split("_") |> then(fn [h | t] -> h <> Enum.map_join(t, &String.capitalize/1) end)
end
