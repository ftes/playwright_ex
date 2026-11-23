# Releases a version: `scripts/release [--dry-run] <version>`, see CONTRIBUTING.md "Releasing".
#
# Self-contained and run with `elixir`, not `mix run`: it needs no compiled project, so the same
# file works in another library repo with only `ReleaseScript.Config` changed. It releases from
# a jj working copy, pushes the release commits to the branch and tags the first with `gh api`;
# the tag push starts the release workflow, which publishes to Hex.

defmodule ReleaseScript.Config do
  @moduledoc false

  # The per-repo part: copy this file to another repo and change only this function.
  def config do
    %{
      # owner/repo for `gh`.
      repo: "ftes/playwright_ex",
      # The jj remote to fetch from and push to; `RELEASE_REMOTE` overrides it.
      remote: System.get_env("RELEASE_REMOTE", "origin"),
      branch: "main",
      # The workflow a pushed `v*` tag starts.
      workflow: "release.yml",
      hex_package: "playwright_ex",
      # The version snippets to bump besides `@version` in mix.exs: each regex's one group is
      # the version, and each file must match at least once.
      snippets: [
        {"README.md", ~r/\{:playwright, "~> ([^"]+)", hex: :playwright_ex\}/},
        {"usage-rules.md", ~r/\{:playwright, "~> ([^"]+)", hex: :playwright_ex\}/}
      ],
      # Adds the release's `Drives [Playwright …]` line from DRIVER_VERSION and NODE_VERSION.
      driver_line: true
    }
  end
end

defmodule ReleaseScript.Error do
  defexception [:message]
end

defmodule ReleaseScript.Edit do
  @moduledoc false
  # The release's checks and file edits: pure, string in, string out.

  alias ReleaseScript.Error

  @unreleased "## [Unreleased]"

  def parse_version(version) do
    case Version.parse(version) do
      {:ok, _} -> version
      :error -> raise Error, "#{inspect(version)} is not a SemVer version (1.2.3 or 1.2.3-rc.1, no v)"
    end
  end

  def newer?(version, current), do: Version.compare(version, current) == :gt

  def current_version(mix_exs) do
    case Regex.run(version_regex(), mix_exs, capture: :all_but_first) do
      [version] -> version
      nil -> raise Error, ~s(no `  @version "..."` line in mix.exs)
    end
  end

  def set_version(mix_exs, version), do: bump(mix_exs, version_regex(), version)

  # A function, not an attribute: OTP 28 can't store a compiled regex in one.
  defp version_regex, do: ~r/^  @version "([^"]+)"$/m

  # Replaces each match's group with the version.
  def bump(content, regex, version) do
    case Regex.scan(regex, content, return: :index, capture: :all_but_first) do
      [] ->
        raise Error, "no match for ~r/#{Regex.source(regex)}/"

      matches ->
        matches
        |> Enum.reverse()
        |> Enum.reduce(content, fn [{start, length}], acc ->
          binary_part(acc, 0, start) <> version <> binary_part(acc, start + length, byte_size(acc) - start - length)
        end)
    end
  end

  def unreleased_content?(changelog) do
    {_, body_start, body_end} = section!(changelog, @unreleased)
    String.trim(binary_part(changelog, body_start, body_end - body_start)) != ""
  end

  def release_heading(changelog, version, date) do
    {start, body_start, _} = section!(changelog, @unreleased)
    splice(changelog, start, body_start, "## [#{version}] #{Date.to_iso8601(date)}")
  end

  # Starts the version's section with the driver line, unless it has one. "No upstream API
  # changes." when the previous release drove the same Playwright.
  def driver_line(changelog, version, driver, node) do
    {_, body_start, body_end} = section!(changelog, "## [#{version}]")
    body = binary_part(changelog, body_start, body_end - body_start)

    if body =~ "Drives [Playwright " do
      changelog
    else
      same? = previous_driver(changelog, body_end) == driver

      line =
        "Drives [Playwright #{driver}](https://github.com/microsoft/playwright/releases/tag/v#{driver}), on\n" <>
          "Node #{node}." <> if(same?, do: " No upstream API changes.", else: "")

      splice(changelog, body_start, body_end, "\n\n" <> line <> "\n\n" <> String.trim_leading(body, "\n"))
    end
  end

  # An empty `## [Unreleased]` above the version's section.
  def start_next(changelog, version) do
    {start, _, _} = section!(changelog, "## [#{version}]")
    splice(changelog, start, start, @unreleased <> "\n\n")
  end

  defp previous_driver(changelog, from) do
    rest = binary_part(changelog, from, byte_size(changelog) - from)

    with [{start, _} | _] <- Regex.run(~r/^## \[/m, rest, return: :index),
         {_, body_start, body_end} = section_at(rest, start),
         [driver] <-
           Regex.run(~r/Drives \[Playwright ([^\]]+)\]/, binary_part(rest, body_start, body_end - body_start),
             capture: :all_but_first
           ) do
      driver
    else
      _ -> nil
    end
  end

  # The section whose heading is `heading`, or starts with `heading` and a space: the heading's
  # start, the body's start (the heading line's end) and the body's end (the next `## ` heading).
  defp section!(changelog, heading) do
    regex = ~r/^#{Regex.escape(heading)}( .*)?$/m

    case Regex.scan(regex, changelog, return: :index, capture: :first) do
      [[{start, _}]] -> section_at(changelog, start)
      [] -> raise Error, "no `#{heading}` heading in the changelog"
      _ -> raise Error, "more than one `#{heading}` heading in the changelog"
    end
  end

  defp section_at(text, start) do
    body_start =
      case :binary.match(text, "\n", scope: {start, byte_size(text) - start}) do
        {line_end, _} -> line_end
        :nomatch -> byte_size(text)
      end

    rest = binary_part(text, body_start, byte_size(text) - body_start)

    case Regex.run(~r/^## /m, rest, return: :index) do
      [{next, _}] -> {start, body_start, body_start + next}
      nil -> {start, body_start, byte_size(text)}
    end
  end

  defp splice(text, from, to, insert),
    do: binary_part(text, 0, from) <> insert <> binary_part(text, to, byte_size(text) - to)
end

defmodule ReleaseScript do
  @moduledoc false
  # The command line: guards, then the edits, two jj commits, the push and the tag.

  alias ReleaseScript.{Config, Edit, Error}

  @usage """
  Usage: scripts/release [--dry-run] <version>

    --dry-run  run the checks and print the release's edits; changes and pushes nothing
  """

  def main(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: [dry_run: :boolean, help: :boolean])

    cond do
      opts[:help] -> IO.write(@usage)
      invalid != [] or length(args) != 1 -> abort(@usage)
      true -> release(hd(args), Keyword.get(opts, :dry_run, false))
    end
  rescue
    error in Error -> abort(error.message)
  end

  defp release(version, dry_run?) do
    c = Config.config()
    version = Edit.parse_version(version)
    target = "#{c.branch}@#{c.remote}"

    step("Fetching #{c.remote}")
    run!("jj", ["git", "fetch", "--remote", c.remote])
    check_clean!(target)

    changelog = File.read!("CHANGELOG.md")
    mix_exs = File.read!("mix.exs")
    current = Edit.current_version(mix_exs)

    unless Edit.unreleased_content?(changelog), do: raise(Error, "`## [Unreleased]` in CHANGELOG.md is empty")
    unless Edit.newer?(version, current), do: raise(Error, "#{version} isn't greater than @version #{current}")
    check_no_tag!(c.repo, "v#{version}")

    released = release_changelog(c, changelog, version)
    next = Edit.start_next(released, version)

    files =
      [{"mix.exs", mix_exs, Edit.set_version(mix_exs, version)}, {"CHANGELOG.md", changelog, released}] ++
        for {path, regex} <- c.snippets do
          content = File.read!(path)
          {path, content, bump!(path, content, regex, version)}
        end

    if dry_run? do
      step("Commit 1, \"Release #{version}\" (tagged v#{version})")
      Enum.each(files, fn {path, old, new} -> IO.write(diff(path, old, new)) end)
      step("Commit 2, \"Start the next release\"")
      IO.write(diff("CHANGELOG.md", released, next))

      IO.puts(
        "\nDry run: nothing changed. Without --dry-run, this commits both, pushes #{c.branch} to " <>
          "#{c.remote} and tags commit 1 v#{version} on GitHub."
      )
    else
      publish(c, version, files, next)
    end
  end

  defp release_changelog(c, changelog, version) do
    released = Edit.release_heading(changelog, version, today())

    if c.driver_line do
      Edit.driver_line(released, version, read_version!("DRIVER_VERSION"), read_version!("NODE_VERSION"))
    else
      released
    end
  end

  defp publish(c, version, files, next) do
    target = "#{c.branch}@#{c.remote}"
    op = capture!("jj", ["op", "log", "--no-graph", "-n", "1", "-T", "id.short(12)"])
    undo = "Nothing is pushed: `jj op restore #{op}` undoes the release commits."

    {release, start_next} =
      or_hint(undo, fn ->
        Enum.each(files, fn {path, _, new} -> File.write!(path, new) end)
        run!("jj", ["commit", "-m", "Release #{version}"])
        release = capture!("jj", ["log", "--no-graph", "-r", "@-", "-T", "change_id"])
        File.write!("CHANGELOG.md", next)
        run!("jj", ["commit", "-m", "Start the next release"])
        {release, capture!("jj", ["log", "--no-graph", "-r", "@-", "-T", "change_id"])}
      end)

    or_hint("Check whether #{c.branch} reached #{c.remote} (`jj log -r #{target}`). " <> undo, fn ->
      step("Pushing #{c.branch} to #{c.remote}")
      run!("jj", ["bookmark", "track", c.branch, "--remote", c.remote])
      run!("jj", ["bookmark", "set", c.branch, "-r", start_next])
      run!("jj", ["git", "push", "--remote", c.remote, "-b", c.branch])
    end)

    # After the push: signing on push rewrites the commits, so their ids are only final now.
    sha = capture!("jj", ["log", "--no-graph", "-r", "#{release} & ::#{target}", "-T", "commit_id"])
    if sha == "", do: raise(Error, "the release commit #{release} isn't on #{target}; not tagging")
    tag = "v#{version}"

    or_hint(
      "#{c.branch} is pushed. Tag the release commit with `gh api repos/#{c.repo}/git/refs -f ref=refs/tags/#{tag} -f sha=#{sha}`.",
      fn ->
        step("Tagging #{String.slice(sha, 0, 12)} #{tag}")
        capture!("gh", ["api", "repos/#{c.repo}/git/refs", "-f", "ref=refs/tags/#{tag}", "-f", "sha=#{sha}"])
      end
    )

    step("Released #{tag}")
    IO.puts("Release run: #{run_url(c, tag)}")

    IO.puts(
      "Approve the staged release on hex.pm (https://hex.pm/packages/#{c.hex_package}) when the run waits for it."
    )
  end

  defp check_clean!(target) do
    empty? = capture!("jj", ["log", "--no-graph", "-r", "@", "-T", "empty"]) == "true"
    parents = capture!("jj", ["log", "--no-graph", "-r", "@-", "-T", ~s(commit_id ++ "\\n")])
    tip = capture!("jj", ["log", "--no-graph", "-r", target, "-T", "commit_id"])

    unless empty? and String.split(parents) == [tip] do
      raise Error, "the working copy isn't clean: release from an empty @ on #{target} (`jj new #{target}`)"
    end
  end

  defp check_no_tag!(repo, tag) do
    refs = capture!("gh", ["api", "repos/#{repo}/git/matching-refs/tags/#{tag}", "--jq", ".[].ref"])
    if "refs/tags/#{tag}" in String.split(refs), do: raise(Error, "the tag #{tag} exists on GitHub")
  end

  defp bump!(path, content, regex, version) do
    Edit.bump(content, regex, version)
  rescue
    error in Error -> reraise Error, "#{path}: #{error.message}", __STACKTRACE__
  end

  defp read_version!(path), do: path |> File.read!() |> String.trim()

  # The run the tag started: it can take a few seconds to show up.
  defp run_url(c, tag, attempts \\ 10) do
    url =
      capture!("gh", [
        "run",
        "list",
        "--repo",
        c.repo,
        "--workflow",
        c.workflow,
        "--branch",
        tag,
        "--limit",
        "1",
        "--json",
        "url",
        "--jq",
        ".[].url"
      ])

    cond do
      url != "" ->
        url

      attempts > 1 ->
        Process.sleep(3_000)
        run_url(c, tag, attempts - 1)

      true ->
        "not listed yet, see https://github.com/#{c.repo}/actions/workflows/#{c.workflow}"
    end
  end

  # A unified diff of the changed lines, with two lines of context.
  defp diff(path, old, new) do
    chunks = List.myers_difference(String.split(old, "\n"), String.split(new, "\n"))
    last = length(chunks) - 1

    lines =
      chunks
      |> Enum.with_index()
      |> Enum.flat_map(fn
        {{:eq, lines}, i} -> context(lines, i == 0, i == last)
        {{:del, lines}, _} -> Enum.map(lines, &("-" <> &1))
        {{:ins, lines}, _} -> Enum.map(lines, &("+" <> &1))
      end)

    Enum.join(["--- a/#{path}", "+++ b/#{path}" | lines], "\n") <> "\n"
  end

  defp context(lines, first?, last?) do
    head = if first?, do: [], else: Enum.take(lines, 2)
    tail = if last?, do: [], else: Enum.take(lines, -2)

    cond do
      length(lines) <= length(head) + length(tail) -> Enum.map(lines, &(" " <> &1))
      last? -> Enum.map(head, &(" " <> &1))
      true -> Enum.map(head, &(" " <> &1)) ++ ["@@"] ++ Enum.map(tail, &(" " <> &1))
    end
  end

  defp today do
    {date, _} = :calendar.local_time()
    Date.from_erl!(date)
  end

  # `env -u DEVELOPER_DIR`: a leaked one can keep jj and gh from finding git's tools.
  defp run!(tool, args) do
    case System.cmd("env", ["-u", "DEVELOPER_DIR", tool | args], into: IO.stream()) do
      {_, 0} -> :ok
      {_, status} -> raise Error, "`#{Enum.join([tool | args], " ")}` exited with #{status}"
    end
  end

  defp capture!(tool, args) do
    case System.cmd("env", ["-u", "DEVELOPER_DIR", tool | args]) do
      {out, 0} -> String.trim(out)
      {out, status} -> raise Error, "`#{Enum.join([tool | args], " ")}` exited with #{status}\n#{out}"
    end
  end

  defp or_hint(hint, fun) do
    fun.()
  rescue
    error -> reraise Error, Exception.message(error) <> "\n" <> hint, __STACKTRACE__
  end

  defp step(message), do: IO.puts(IO.ANSI.format([:bright, "==> ", message]))

  defp abort(message) do
    IO.puts(:stderr, "release: " <> String.trim_trailing(message))
    System.halt(1)
  end
end
