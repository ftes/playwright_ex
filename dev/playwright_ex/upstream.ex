defmodule PlaywrightEx.Upstream do
  @moduledoc """
  The microsoft/playwright sources at the pinned `PlaywrightEx.Driver.version/0`, for the
  dev tasks (`mix playwright_ex.gen.protocol`, `mix playwright_ex.parity`), the tests (test server
  assets) and reading (`mix playwright_ex.upstream`).

  Downloads the release tarball once into `PlaywrightEx.Driver.cache_dir/0` and extracts only
  `@paths` (again when a path is missing, e.g. after one was added). `PLAYWRIGHT_EX_UPSTREAM` points at a checkout instead.
  """
  alias PlaywrightEx.Driver

  # packages/injected/src for reading: the driver bundles the injected script as one escaped string.
  @paths ~w(
    packages/playwright-core/src packages/playwright/src packages/protocol packages/isomorphic packages/utils
    packages/injected/src utils docs/src/api tests/page tests/library tests/config tests/assets
  )

  def dir, do: env() || Path.join([Driver.cache_dir(), Driver.version(), "upstream"])

  @doc "Returns `dir/0`, downloading and extracting the sources first if needed."
  def ensure! do
    dir = dir()

    cond do
      env() ->
        if not File.dir?(dir), do: raise("upstream checkout not found: #{dir}")

      complete?(dir) ->
        :ok

      true ->
        install_once!(dir)
    end

    dir
  end

  # Concurrent callers (test modules' `setup_all`) wait for one download instead of racing it.
  defp install_once!(dir) do
    :global.trans(
      {{__MODULE__, dir}, self()},
      fn -> if not complete?(dir), do: reinstall!(dir) end,
      [node()],
      :infinity
    )
  end

  defp complete?(dir), do: Enum.all?(@paths, &File.dir?(Path.join(dir, &1)))

  defp reinstall!(dir) do
    File.rm_rf!(dir)
    install!(dir)
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
        {_, 0} -> rename!(out, dir)
        {output, status} -> raise "extracting #{tgz} failed (#{status}): #{output}"
      end
    after
      File.rm_rf!(tmp)
    end
  end

  # Another OS process (a parallel `mix test`) may have installed it meanwhile.
  defp rename!(out, dir) do
    case File.rename(out, dir) do
      :ok ->
        :ok

      {:error, reason} ->
        if not complete?(dir),
          do: raise(File.RenameError, reason: reason, source: out, destination: dir, action: "rename")
    end
  end

  defp env, do: "PLAYWRIGHT_EX_UPSTREAM" |> System.get_env() |> then(&if(&1 in [nil, ""], do: nil, else: &1))
end
