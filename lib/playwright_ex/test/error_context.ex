defmodule PlaywrightEx.Test.ErrorContext do
  @moduledoc false
  # Upstream's `buildErrorContext` (`packages/playwright/src/errorContext.ts`): the
  # `error-context.md` of a failed test, from its failures (`{kind, reason, stacktrace}` as
  # ExUnit's, or a message: `PlaywrightEx.Test.Pool.result/2`) in place of `testInfo.errors`.

  alias PlaywrightEx.Isomorphic.StringUtils

  @fix_test_instructions """
  # Instructions

  - Following Playwright test failed.
  - Explain why, be concise, respect Playwright best practices.
  - Provide a snippet of code with the fix, if possible.
  """

  @doc """
  `testInfoError`: a failure as upstream's `TestInfoError`, `message` as `filterStackTrace`'s
  (`name: message`), `error_context` a failed matcher's aria snapshot.
  """
  def error(message) when is_binary(message), do: %{message: message, stack: [], error_context: nil}

  def error({kind, reason, stack}) do
    message =
      if kind == :error and is_exception(reason),
        do: inspect(reason.__struct__) <> ": " <> String.trim(Exception.message(reason)),
        else: Exception.format_banner(kind, reason, stack)

    error_context =
      case reason do
        %PlaywrightEx.ExpectError{matcherResult: %{ariaSnapshot: snapshot}} when snapshot != "" -> snapshot
        _ -> nil
      end

    %{message: message, stack: stack, error_context: error_context}
  end

  @doc """
  `didFinishTest`'s end: writes `error-context.md` of the test `test` (its registration:
  `output_dir`, `title_path`, `location`) for the `failures`, with `page_snapshot` unless a
  failed matcher carries its own.
  """
  def write(test, failures, page_snapshot \\ nil) do
    errors = Enum.map(failures, &error/1)
    page_snapshot = if !Enum.any?(errors, & &1.error_context), do: page_snapshot

    if content =
         build(%{title_path: test.title_path, location: test.location, errors: errors, page_snapshot: page_snapshot}) do
      File.mkdir_p!(test.output_dir)
      File.write!(Path.join(test.output_dir, "error-context.md"), content)
    end
  end

  @doc "`buildErrorContext`: the markdown, or `nil`. `location` is `{file, line}` (ExUnit has no column)."
  def build(%{title_path: title_path, location: {file, line}, errors: errors, page_snapshot: page_snapshot}) do
    meaningful_errors = Enum.filter(errors, &(&1.message not in [nil, ""]))
    page_snapshot = if page_snapshot != "", do: page_snapshot

    if meaningful_errors != [] or page_snapshot do
      lines =
        [
          @fix_test_instructions,
          "# Test info",
          "",
          "- Name: #{Enum.join(title_path, " >> ")}",
          "- Location: #{Path.relative_to_cwd(file)}:#{line}"
        ] ++ error_details(meaningful_errors) ++ page_snapshot(page_snapshot)

      code_frame = meaningful_errors |> List.last() |> code_frame()
      lines = if code_frame, do: lines ++ ["", "# Test source", "", "```elixir", code_frame, "```"], else: lines
      Enum.join(lines, "\n")
    end
  end

  defp error_details([]), do: []

  defp error_details(errors) do
    ["", "# Error details"] ++
      Enum.flat_map(errors, fn error ->
        ["", "```", StringUtils.strip_ansi_escapes(error.message), "```"] ++
          if error.error_context, do: ["", "```yaml", error.error_context, "```"], else: []
      end)
  end

  defp page_snapshot(nil), do: []
  defp page_snapshot(snapshot), do: ["", "# Page snapshot", "", "```yaml", snapshot, "```"]

  # `buildCodeFrame`: 100 lines around the error's location, the first frame in the project's
  # `test/` (upstream's first frame outside `node_modules`).
  defp code_frame(nil), do: nil

  defp code_frame(error) do
    with {file, line, column} <- error_location(error.stack),
         {:ok, source} <- File.read(file) do
      source_lines = String.split(source, "\n")
      start = max(0, line - 100 - 1)
      ending = min(length(source_lines), line + 100)
      width = String.length(to_string(ending))
      message = error.message |> StringUtils.strip_ansi_escapes() |> String.split("\n") |> hd()

      frame =
        for {text, number} <- Enum.with_index(Enum.slice(source_lines, start..(ending - 1)//1), start + 1),
            do: "#{marker(number, line)}#{String.pad_trailing(to_string(number), width)} | #{text}"

      caret = "#{String.duplicate(" ", width + 2)} | #{String.duplicate(" ", max(0, column - 2))} ^ #{message}"
      frame = if message != "", do: List.insert_at(frame, line - start, caret), else: frame
      Enum.join(frame, "\n")
    else
      _ -> nil
    end
  end

  defp marker(line, line), do: "> "
  defp marker(_number, _line), do: "  "

  defp error_location(stack) do
    test_dir = PlaywrightEx.Test.TestInfo.test_dir() <> "/"

    Enum.find_value(stack, fn
      {_module, _fun, _arity, location} ->
        file = location[:file] && Path.expand(to_string(location[:file]))

        if file && location[:line] && String.starts_with?(file, test_dir),
          do: {file, location[:line], location[:column] || 0}

      _ ->
        nil
    end)
  end
end
