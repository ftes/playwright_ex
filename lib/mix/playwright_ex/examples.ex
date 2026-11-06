defmodule Mix.PlaywrightEx.Examples do
  @moduledoc false
  # The Elixir translations of the facade docs' JS examples: the `example` tests in
  # `test/examples/*.exs` (`PlaywrightEx.ExampleCase`), read as source, not compiled.
  # `mix playwright_ex.gen.api` renders a body in place of the upstream block equal to its `js:`.

  @dir "test/examples"

  # %{js => elixir source} of every example.
  def load(dir \\ @dir) do
    for path <- Path.wildcard(Path.join(dir, "*.exs")), {js, source} <- examples(path), reduce: %{} do
      acc ->
        if Map.has_key?(acc, js), do: Mix.raise("gen.api: two examples for the same JS in #{path}:\n#{js}")
        Map.put(acc, js, source)
    end
  end

  # Translations whose JS is no longer upstream's (`js` is every JS block of the docs).
  def stale(examples, js), do: Map.keys(examples) -- js

  defp examples(path) do
    source = File.read!(path)
    lines = String.split(source, "\n")
    ast = Code.string_to_quoted!(source, file: path, token_metadata: true)

    {_, acc} =
      Macro.prewalk(ast, [], fn
        {:example, meta, [_member, opts, [do: _]]} = node, acc ->
          {node, [{js!(path, opts), body(lines, meta)} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(acc)
  end

  defp js!(path, opts) do
    case opts[:js] do
      {:sigil_S, _, [{:<<>>, _, [js]}, []]} -> String.trim_trailing(js)
      js when is_binary(js) -> String.trim_trailing(js)
      _ -> Mix.raise("gen.api: an example in #{path} has no literal js:")
    end
  end

  # The lines between `do` and `end`, dedented.
  defp body(lines, meta) do
    body = Enum.slice(lines, meta[:do][:line]..(meta[:end][:line] - 2)//1)
    indent = body |> Enum.reject(&(String.trim(&1) == "")) |> Enum.map(&indent/1) |> Enum.min()
    Enum.map_join(body, "\n", &String.slice(&1, indent..-1//1))
  end

  defp indent(line), do: String.length(line) - String.length(String.trim_leading(line))
end
