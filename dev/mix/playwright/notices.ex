defmodule Mix.Playwright.Notices do
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
  generators (`mix playwright.gen.api`, `mix playwright.gen.protocol`) put the header on
  what they write, `mix playwright.notices` on the other files, and `mix playwright.parity`
  checks both. `NOTICE` must name the copyright lines of every MIT source but Microsoft's.

  It also keeps the upstream runner files a version bump diffs (`runner_sources/0`, printed by
  `mix playwright.runner_sources`): `@derived`'s and `@watched`'s, which must hold every
  `packages/playwright/{src,types}/` file `lib/playwright/test.ex`, `lib/playwright/test/` and
  `lib/playwright/case.ex` cite (outside `src/matchers/`).
  """

  alias Mix.Tasks.Playwright.Parity

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
    "lib/playwright/abort_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright/playwright_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright/target_closed_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright/timeout_error.ex" => ["packages/playwright-core/src/client/errors.ts"],
    "lib/playwright/expect_error.ex" => ["packages/playwright/src/matchers/matcherHint.ts"],
    "lib/playwright/matchers/matcher_utils.ex" => @jest,
    "lib/playwright/test/error_context.ex" => ["packages/playwright/src/errorContext.ts"],
    "lib/playwright/test/github_formatter.ex" => ["packages/playwright/src/reporters/github.ts"],
    "lib/playwright/test/json_formatter.ex" => ["packages/playwright/src/reporters/json.ts"],
    "lib/playwright/test/test_info.ex" => ["packages/playwright/src/worker/testInfo.ts"],
    "lib/playwright/test/test_tracing.ex" => ["packages/playwright/src/worker/testTracing.ts"]
  }
  # Upstream runner files `Playwright.Test` follows (cites, takes names, defaults or behaviour
  # from) without deriving a file from, path => why. With `@derived`'s runner files they are what
  # a bump diffs (`runner_sources/0`); `check/1` fails on a runner citation listed in neither.
  @watched %{
    "packages/playwright/src/common/config.ts" => "defaults (`defaultTimeout`, `snapshotPathTemplate`)",
    "packages/playwright/src/common/process.ts" => "the worker process the browser pool stands in for",
    "packages/playwright/src/common/testType.ts" => "the test API (`test.step`, `test.step.skip`, `test.slow`)",
    "packages/playwright/src/index.ts" => "fixtures, options and their defaults, the artifact recording",
    "packages/playwright/src/reporters/base.ts" =>
      "what the GitHub formatter uses of `TerminalReporter`, the JSON formatter's `resolveOutputFile`",
    "packages/playwright/src/runner/dispatcher.ts" => "worker reuse and stop after a failure (the pool)",
    "packages/playwright/src/util.ts" => "testInfo's path helpers (`sanitizeForFilePath`, `trimLongString`)",
    "packages/playwright/src/worker/timeoutManager.ts" => "the `setup_all` timeout and its error",
    "packages/playwright/src/worker/util.ts" => "testInfo's errors (`testInfoError`)",
    "packages/playwright/src/worker/workerMain.ts" => "output dir cleanup and `preserveOutput`",
    "packages/playwright/types/test.d.ts" => "the options' types and object forms",
    "packages/playwright/types/testReporter.d.ts" => "the JSON report's types (`JSONReport`)"
  }
  # The runner files whose upstream citations must be in `runner_sources/0`.
  @runner_files ~w(lib/playwright/test.ex lib/playwright/case.ex lib/playwright/test/**/*.ex)
  @runner_citation ~r{packages/playwright/(?:src|types)/[\w./-]+\.ts}

  # The generated facade and the translations of its examples, from upstream's docs.
  @derived_dirs %{"lib/playwright/api/" => @docs, "test/examples/" => @docs}

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

  @doc """
  The upstream runner files a version bump diffs (PORTING.md, "Bumping the pinned version"):
  `@derived`'s under `packages/playwright/` outside `src/matchers/` (which the ported diff
  covers), and `@watched`, sorted.
  """
  def runner_sources do
    derived = for {_, paths} <- @derived, is_list(paths), path <- paths, runner_source?(path), do: path
    Enum.sort(Enum.uniq(derived ++ Map.keys(@watched)))
  end

  defp runner_source?(path) do
    String.starts_with?(path, "packages/playwright/") and
      not String.starts_with?(path, "packages/playwright/src/matchers/")
  end

  @doc false
  # Problems for runner `files` (`{path, source}`) citing an upstream runner file that `listed`
  # lacks, and for `listed` paths that `upstream` lacks.
  def check_runner_sources(upstream, files, listed) do
    unlisted =
      for {path, source} <- files,
          [cited] <- Regex.scan(@runner_citation, source),
          runner_source?(cited),
          cited not in listed,
          uniq: true,
          do: "#{path}: cites #{cited}, list it in Mix.Playwright.Notices @watched with a reason"

    stale =
      for path <- listed,
          not File.regular?(Path.join(upstream, path)),
          do: "#{path}: a runner source in Mix.Playwright.Notices, but not found upstream, drop it"

    unlisted ++ stale
  end

  @doc """
  Problems: files whose header is out of date, stale `@derived` paths, MIT notices missing from
  `NOTICE`, runner citations missing from `runner_sources/0` and its paths missing upstream.
  """
  def check(upstream) do
    notice = File.read!("NOTICE")
    files = for path <- files(), do: {path, File.read!(path)}

    headers =
      for {path, source} <- files, put(upstream, path, source) != source do
        fix = if generated?(source), do: "regenerate it", else: "run mix playwright.notices"
        "#{path}: copyright header out of date, #{fix}"
      end

    stale =
      for {path, _} <- @derived,
          not File.regular?(path),
          do: "#{path}: in Mix.Playwright.Notices @derived, but not found"

    mit =
      for {path, source} <- files,
          {lines, "MIT"} <- Enum.map(sources(path, source), &notice(upstream, &1)),
          line <- lines,
          not String.contains?(line, "Microsoft"),
          not String.contains?(notice, line),
          uniq: true,
          do: "NOTICE: missing #{inspect(line)} (MIT, #{path})"

    runner = for pattern <- @runner_files, path <- Path.wildcard(pattern), do: {path, File.read!(path)}

    headers ++ stale ++ mit ++ check_runner_sources(upstream, runner, runner_sources())
  end

  @doc "`{copyright lines, license}` of an upstream path (or a `{lines, license}` as is)."
  def notice(_upstream, {lines, license}), do: {lines, license}

  def notice(upstream, path) do
    file = Path.join(upstream, path)
    if not File.regular?(file), do: Mix.raise("notices: #{path} not found upstream")
    comment = leading_comment(File.read!(file))
    lines = Enum.filter(comment, &Regex.match?(~r/^(Modifications |Portions )?copyright\b/i, &1))
    text = Enum.join(comment, " ")

    # A file without a header, or without license text, is under upstream's root LICENSE (Apache-2.0)
    # and NOTICE (Microsoft's copyright), which we ship. Every header keeps a copyright line:
    # `strip/1` finds headers by it.
    license =
      if text =~ "Permission is hereby granted" or text =~ ~r/MIT license/i, do: "MIT", else: "Apache-2.0"

    {if(lines == [], do: [@microsoft], else: lines), license}
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
