defmodule PlaywrightEx.Upstream do
  @moduledoc """
  The microsoft/playwright sources at the pinned `PlaywrightEx.Driver.version/0`, for the
  dev tasks (`mix playwright_ex.gen.protocol`, `mix playwright_ex.parity`) and the tests
  (test server assets).

  Downloads the release tarball once into `PlaywrightEx.Driver.cache_dir/1` and extracts only
  `@paths`. `PLAYWRIGHT_EX_UPSTREAM` (or the `:dir` option) points at a checkout instead.
  """
  alias PlaywrightEx.Driver

  @paths ~w(
    packages/playwright-core/src packages/protocol packages/isomorphic packages/utils utils
    tests/page tests/library tests/config tests/assets
  )

  def dir(opts \\ []) do
    opts[:dir] || env() || Path.join([Driver.cache_dir(opts), Driver.version(), "upstream"])
  end

  @doc "Returns `dir/1`, downloading and extracting the sources first if needed."
  def ensure!(opts \\ []) do
    dir = dir(opts)

    if not File.dir?(dir) do
      if opts[:dir] || env(), do: raise("upstream checkout not found: #{dir}")
      install!(dir)
    end

    dir
  end

  defp install!(dir) do
    version = Driver.version()
    tmp = "#{dir}.tmp-#{System.unique_integer([:positive])}"
    File.mkdir_p!(tmp)

    try do
      tgz = Path.join(tmp, "playwright.tar.gz")
      IO.puts(:stderr, "Downloading microsoft/playwright v#{version} sources")
      Driver.download!("https://codeload.github.com/microsoft/playwright/tar.gz/refs/tags/v#{version}", tgz)

      out = Path.join(tmp, "src")
      File.mkdir_p!(out)
      members = Enum.map(@paths, &"playwright-#{version}/#{&1}")

      case System.cmd("tar", ["-xzf", tgz, "--strip-components=1", "-C", out | members], stderr_to_stdout: true) do
        {_, 0} -> File.rename!(out, dir)
        {output, status} -> raise "extracting #{tgz} failed (#{status}): #{output}"
      end
    after
      File.rm_rf!(tmp)
    end
  end

  defp env, do: "PLAYWRIGHT_EX_UPSTREAM" |> System.get_env() |> then(&if(&1 in [nil, ""], do: nil, else: &1))
end
