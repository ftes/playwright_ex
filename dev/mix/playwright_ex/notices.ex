defmodule Mix.PlaywrightEx.Notices do
  @moduledoc """
  The copyright header of a file derived from upstream (Apache-2.0, section 4): its upstream
  files' copyright lines, a line stating that it was ported and modified, and the license, as a
  comment block at the top of the file:

      # Copyright 2018 Google Inc. All rights reserved.
      # Modifications copyright (c) Microsoft Corporation.
      # Ported to Elixir and modified by the playwright_ex authors.
      # SPDX-License-Identifier: Apache-2.0

  The sources of a file are its modules' `@upstream` paths (`.ex` and `.exs` under `lib`, `dev`
  and `test`), else `@derived` below. The copyright lines are those at the start of each
  upstream file's leading comment; the license is that comment's (Apache-2.0 or MIT). The
  generators (`mix playwright_ex.gen.api`, `mix playwright_ex.gen.protocol`) put the header on
  what they write, `mix playwright_ex.notices` on the other files, and `mix playwright_ex.parity`
  checks both. `NOTICE` must name the copyright lines of every MIT source but Microsoft's.
  """

  alias Mix.Tasks.PlaywrightEx.Parity

  @dirs ~w(lib dev test)
  @ported "Ported to Elixir and modified by the playwright_ex authors."
  @microsoft "Copyright (c) Microsoft Corporation."
  # `{lines, license}` of sources outside the Playwright repository.
  @jest {["Copyright (c) Meta Platforms, Inc. and affiliates."], "MIT"}
  # Upstream's docs (docs/src/api) have no headers: the repository's notice.
  @docs {[@microsoft], "Apache-2.0"}

  # Files derived from upstream without `@upstream` (parity does not compare them method by
  # method), path => upstream paths or `{lines, license}`.
  @derived %{
    "lib/playwright_ex/abort_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright_ex/playwright_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright_ex/target_closed_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright_ex/timeout_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright_ex/expect_error.ex" => ["packages/playwright/src/matchers/matcherHint.ts"],
    "lib/playwright_ex/matchers/matcher_utils.ex" => @jest,
    "lib/playwright_ex/test/error_context.ex" => ["packages/playwright/src/errorContext.ts"],
    "lib/playwright_ex/test/github_formatter.ex" => ["packages/playwright/src/reporters/github.ts"],
    "lib/playwright_ex/test/test_info.ex" => ["packages/playwright/src/worker/testInfo.ts"],
    "lib/playwright_ex/test/test_tracing.ex" => ["packages/playwright/src/worker/testTracing.ts"]
  }
  # The generated facade and the translations of its examples, from upstream's docs.
  @derived_dirs %{"lib/playwright_ex/api/" => @docs, "test/examples/" => @docs}

  @header ~r/\A# [^\n]*[Cc]opyright[^\n]*\n(?:# [^\n]*\n)*?# SPDX-License-Identifier: [^\n]*\n\n/

  @doc "The files that may carry a header, relative to the project root."
  def files, do: Enum.flat_map(@dirs, &Path.wildcard("#{&1}/**/*.{ex,exs}"))

  @doc "Whether `source` is a generator's output: its first line after the header says so."
  def generated?(source), do: source |> strip() |> String.starts_with?("# This file is generated")

  @doc "`source` without its header."
  def strip(source), do: String.replace(source, @header, "", global: false)

  @doc """
  `source` of `path` with the header its sources give, replacing the one it has (none when it
  has no sources). `upstream` is the upstream checkout.
  """
  def put(upstream, path, source) do
    case header(upstream, path, source) do
      nil -> strip(source)
      header -> header <> strip(source)
    end
  end

  @doc "The header of `path`, or `nil`."
  def header(upstream, path, source) do
    case sources(path, source) do
      [] -> nil
      sources -> sources |> Enum.map(&notice(upstream, &1)) |> render()
    end
  end

  @doc "The sources of `path`: upstream paths and `{lines, license}`."
  def sources(path, source) do
    own =
      source
      |> Parity.elixir_modules_of(path)
      |> Enum.filter(& &1.declares_upstream)
      |> Enum.map(& &1.upstream)
      |> Enum.uniq()

    cond do
      own != [] -> own
      derived = @derived[path] -> List.wrap(derived)
      dir = Enum.find(Map.keys(@derived_dirs), &String.starts_with?(path, &1)) -> [@derived_dirs[dir]]
      true -> []
    end
  end

  @doc "Problems: files whose header is out of date, stale `@derived` paths, MIT notices missing from `NOTICE`."
  def check(upstream) do
    notice = File.read!("NOTICE")
    files = for path <- files(), do: {path, File.read!(path)}

    headers =
      for {path, source} <- files, put(upstream, path, source) != source do
        fix = if generated?(source), do: "regenerate it", else: "run mix playwright_ex.notices"
        "#{path}: copyright header out of date, #{fix}"
      end

    stale =
      for {path, _} <- @derived,
          not File.regular?(path),
          do: "#{path}: in Mix.PlaywrightEx.Notices @derived, but not found"

    mit =
      for {path, source} <- files,
          {lines, "MIT"} <- Enum.map(sources(path, source), &notice(upstream, &1)),
          line <- lines,
          not String.contains?(line, "Microsoft"),
          not String.contains?(notice, line),
          uniq: true,
          do: "NOTICE: missing #{inspect(line)} (MIT, #{path})"

    headers ++ stale ++ mit
  end

  @doc "`{copyright lines, license}` of an upstream path (or a `{lines, license}` as is)."
  def notice(_upstream, {lines, license}), do: {lines, license}

  def notice(upstream, path) do
    file = Path.join(upstream, path)
    if not File.regular?(file), do: Mix.raise("notices: #{path} not found upstream")
    comment = leading_comment(File.read!(file))
    lines = Enum.filter(comment, &Regex.match?(~r/^(Modifications |Portions )?copyright\b/i, &1))
    text = Enum.join(comment, " ")

    # A file without a header, or without license text, is under upstream's root LICENSE (Apache-2.0),
    # whose NOTICE we ship: there is nothing more of its own to retain.
    license =
      if text =~ "Permission is hereby granted" or text =~ ~r/MIT license/i, do: "MIT", else: "Apache-2.0"

    {lines, license}
  end

  # The lines of the first `/* */` or `#` comment, past a shebang, without the comment marks.
  defp leading_comment(text) do
    lines = text |> String.split("\n") |> Enum.drop_while(&String.starts_with?(&1, "#!"))

    case lines do
      ["/*" <> _ | _] ->
        lines
        |> Enum.take_while(&(not String.contains?(&1, "*/")))
        |> Enum.map(&String.replace(&1, ~r/^\s*\/?\*+\s?/, ""))

      ["#" <> _ | _] ->
        lines |> Enum.take_while(&String.starts_with?(&1, "#")) |> Enum.map(&String.replace(&1, ~r/^#\s?/, ""))

      _ ->
        []
    end
    |> Enum.map(&String.trim/1)
  end

  defp render(notices) do
    lines = notices |> Enum.flat_map(&elem(&1, 0)) |> Enum.uniq()
    license = notices |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort() |> Enum.join(" AND ")
    Enum.map_join(lines ++ [@ported, "SPDX-License-Identifier: #{license}"], &"# #{&1}\n") <> "\n"
  end
end
