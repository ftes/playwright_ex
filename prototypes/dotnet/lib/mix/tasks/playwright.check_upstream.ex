defmodule Mix.Tasks.Playwright.CheckUpstream do
  @shortdoc "Checks every `# upstream: File.cs:N` comment against a playwright-dotnet checkout"
  @moduledoc """
  For each `# upstream: <path>:<line>[ + :<line>]` comment in lib/, verifies that the referenced
  upstream line mentions the (CamelCased) name of the function defined right below the comment.
  Run against the *new* upstream version while rolling to find ported functions that moved.

      mix playwright.check_upstream <playwright-dotnet>/src/Playwright [--fix]

  With `--fix`, a stale line number is re-anchored to the nearest upstream *declaration* line
  mentioning the name (what a roll needs after upstream inserts/removes lines).
  """
  use Mix.Task

  @impl Mix.Task
  def run([src_dir | flags]) do
    fix? = "--fix" in flags

    results =
      for file <- Path.wildcard("lib/playwright/**/*.ex"),
          not String.contains?(file, "/generated/"),
          {comment, idx, lines} <- upstream_comments(file),
          ref <- refs(comment),
          do: {file, idx, comment, ref, check(src_dir, file, idx, lines, ref)}

    bad = Enum.reject(results, &(elem(&1, 4) == :ok))
    Enum.each(bad, fn {_, _, _, _, msg} -> Mix.shell().error(msg) end)
    Mix.shell().info("#{length(results) - length(bad)}/#{length(results)} upstream references match")
    if fix?, do: fix(src_dir, bad)
  end

  defp fix(src_dir, bad) do
    for {file, entries} <- Enum.group_by(bad, &elem(&1, 0)) do
      lines = file |> File.read!() |> String.split("\n")

      lines =
        Enum.reduce(entries, lines, fn {_, idx, _comment, {path, line_no}, _}, lines ->
          name = next_def(lines, idx + 1)
          upstream = src_dir |> Path.join(path) |> File.read!() |> String.split("\n")
          wanted = wanted(name, path) |> String.downcase()

          candidates =
            for {l, i} <- Enum.with_index(upstream, 1),
                String.contains?(norm(l), norm(wanted)),
                Regex.match?(~r/^\s*(public|internal|private|protected|static|async|\S+ \S+\()/, l),
                do: i

          case Enum.min_by(candidates, &abs(&1 - line_no), fn -> nil end) do
            nil -> lines
            new_no -> List.update_at(lines, idx, &String.replace(&1, "#{path}:#{line_no}", "#{path}:#{new_no}", global: false) |> String.replace(" + :#{line_no}", " + :#{new_no}"))
          end
        end)

      File.write!(file, Enum.join(lines, "\n"))
    end
  end

  defp upstream_comments(file) do
    lines = file |> File.read!() |> String.split("\n")

    for {line, idx} <- Enum.with_index(lines),
        [_, comment] <- [Regex.run(~r/# upstream: (\S+\.cs:\d+(?: \+ :\d+)*)/, line)],
        do: {comment, idx, lines}
  end

  defp refs(comment) do
    [path_line | more] = String.split(comment, " + ")
    [path, line] = String.split(path_line, ":")
    [{path, String.to_integer(line)} | Enum.map(more, &{path, &1 |> String.trim_leading(":") |> String.to_integer()})]
  end

  defp check(src_dir, file, idx, lines, {path, line_no}) do
    upstream = Path.join(src_dir, path)

    with true <- File.exists?(upstream) || "#{file}:#{idx + 1}: #{path} not found",
         name when is_binary(name) <- next_def(lines, idx + 1) || "#{file}:#{idx + 1}: no def after comment",
         line = upstream |> File.read!() |> String.split("\n") |> Enum.at(line_no - 1, ""),
         true <- mentions?(line, name, path) || "#{file}:#{idx + 1}: #{path}:#{line_no} does not mention #{name}: #{String.trim(line)}" do
      :ok
    end
  end

  defp next_def(lines, from) do
    lines
    |> Enum.drop(from)
    |> Enum.find_value(fn l -> with [_, n] <- Regex.run(~r/^\s*defp? ([a-z_0-9?!]+)/, l), do: n end)
  end

  defp mentions?(line, name, path), do: String.contains?(norm(line), norm(wanted(name, path)))
  defp norm(s), do: s |> String.downcase() |> String.replace("_", "")

  defp wanted(name, path) do
      case name do
        n when n in ["new", "start_link"] -> path |> Path.basename(".cs")
        "not_" -> "Not"
        "get" -> "this["
        n -> n |> String.replace_suffix("_async", "") |> String.replace_suffix("_impl", "") |> String.replace_suffix("_internal", "") |> String.replace_suffix("_protocol", "") |> Macro.camelize()
      end
  end
end
