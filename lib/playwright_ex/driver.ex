defmodule PlaywrightEx.Driver do
  @moduledoc """
  Installs and locates the Playwright driver: a pinned `playwright-core` npm package plus
  the pinned Node.js binary for the host platform. No Node.js is needed beforehand.

  Mirrors playwright-python (`scripts/build_driver.py`, `_impl/_driver.py`), except that
  Python assembles the bundle at wheel-build time and we do it lazily on the user's machine.

  Layout (same as Python's `playwright/driver/`):

      <cache_dir>/<driver_version>/<platform>/
        node | node.exe   Node.js binary
        LICENSE           Node.js license
        package/          playwright-core npm package (package/cli.js is the entry point)

  `cache_dir` defaults to `:filename.basedir(:user_cache, "playwright_ex")`, overridable with
  the `:cache_dir` option or `PLAYWRIGHT_EX_CACHE_DIR`.

  Overrides (no download happens when one is set):

    * `executable: path` / `PLAYWRIGHT_EX_EXECUTABLE` - an npm-managed `playwright` CLI
      (e.g. `node_modules/.bin/playwright`), run as `path run-driver`.
    * `node: path` / `PLAYWRIGHT_NODEJS_PATH` - like Python: use this Node binary with the
      cached `package/cli.js` (the package is still installed if missing).
  """

  @checksums_file Path.join([__DIR__, "..", "..", "priv", "driver_checksums.exs"])
  @external_resource @checksums_file
  @checksums @checksums_file |> File.read!() |> Code.eval_string() |> elem(0)

  # One line each at the repo root, as playwright-python's DRIVER_VERSION and NODE_VERSION (whose
  # Node version we follow). CI keys caches on them; upstream-check.sh reads DRIVER_VERSION.
  @driver_version_file Path.join([__DIR__, "..", "..", "DRIVER_VERSION"])
  @node_version_file Path.join([__DIR__, "..", "..", "NODE_VERSION"])
  @external_resource @driver_version_file
  @external_resource @node_version_file
  @driver_version @driver_version_file |> File.read!() |> String.trim()
  @node_version @node_version_file |> File.read!() |> String.trim()

  if @checksums.driver_version != @driver_version or @checksums.node_version != @node_version do
    raise "priv/driver_checksums.exs is stale; run `mix playwright_ex.checksums`"
  end

  @platforms ~w(darwin-arm64 darwin-x64 linux-x64 linux-arm64 win-x64 win-arm64)

  @typedoc """
  An option, overriding its environment variable (see the module docs). `:platform` (nodejs.org
  naming, `"linux-x64"`) installs or locates the driver of another platform than the host's.
  """
  @type option ::
          {:executable, Path.t()} | {:node, Path.t()} | {:cache_dir, Path.t()} | {:platform, String.t()}

  @doc "The pinned Playwright version (`playwright-core` on npm), which the driver runs."
  @spec version() :: String.t()
  def version, do: @driver_version

  @doc "The pinned Node.js version the driver runs on (unless `:node` or `:executable` is set)."
  @spec node_version() :: String.t()
  def node_version, do: @node_version

  @doc false
  def platforms, do: @platforms
  @doc false
  def checksums, do: @checksums

  @doc """
  The driver command: `{program, args_prefix}`, to which `run-driver`, `install ...` etc. are
  appended. Doesn't install, see `ensure_installed/1`.
  """
  @spec executable([option()]) :: {String.t(), [String.t()]}
  def executable(opts \\ []) do
    cond do
      exe = opts[:executable] || env("PLAYWRIGHT_EX_EXECUTABLE") ->
        {Path.expand(exe), []}

      node = opts[:node] || env("PLAYWRIGHT_NODEJS_PATH") ->
        {Path.expand(node), [cli_path(opts)]}

      true ->
        {node_path(opts), [cli_path(opts)]}
    end
  end

  @doc """
  Installs the driver unless it is installed or an override is set (`install/1`), then returns
  `executable/1`. `PlaywrightEx.Supervisor` calls it when it starts.
  """
  @spec ensure_installed([option()]) :: {String.t(), [String.t()]}
  def ensure_installed(opts \\ []) do
    cond do
      opts[:executable] || env("PLAYWRIGHT_EX_EXECUTABLE") ->
        :ok

      File.regular?(cli_path(opts)) and
          (opts[:node] || env("PLAYWRIGHT_NODEJS_PATH") || File.regular?(node_path(opts))) ->
        :ok

      true ->
        install(opts)
    end

    executable(opts)
  end

  @doc "Whether the pinned driver is installed in `install_dir/1`."
  @spec installed?([option()]) :: boolean()
  def installed?(opts \\ []), do: File.dir?(install_dir(opts))

  @doc "Where the pinned driver is (or will be) installed: `<cache_dir>/<version>/<platform>`."
  @spec install_dir([option()]) :: String.t()
  def install_dir(opts \\ []), do: Path.join([cache_dir(opts), @driver_version, opts[:platform] || platform!()])

  @doc """
  The cache directory: the `:cache_dir` option, else `PLAYWRIGHT_EX_CACHE_DIR`, else the user cache
  directory (`:filename.basedir(:user_cache, "playwright_ex")`).
  """
  @spec cache_dir([option()]) :: String.t()
  def cache_dir(opts \\ []) do
    opts[:cache_dir] || env("PLAYWRIGHT_EX_CACHE_DIR") ||
      List.to_string(:filename.basedir(:user_cache, ~c"playwright_ex"))
  end

  @doc """
  Downloads, verifies and extracts the driver. Idempotent; atomic (everything happens in a
  temp dir next to the target, which is renamed into place only after all checks passed).

  Options: `:cache_dir`, `:platform`, `force: true` to reinstall. Raises if a download or a
  checksum fails.
  """
  @spec install([option() | {:force, boolean()}]) :: :ok
  def install(opts \\ []) do
    platform = opts[:platform] || platform!()
    platform in @platforms || unsupported!(platform)
    target = install_dir(Keyword.put(opts, :platform, platform))

    if File.dir?(target) and not Keyword.get(opts, :force, false) do
      :ok
    else
      checksums = opts[:checksums] || @checksums
      parent = Path.dirname(target)
      File.mkdir_p!(parent)
      tmp = Path.join(parent, ".tmp-#{platform}-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)

      try do
        build(tmp, platform, checksums)

        if File.dir?(target), do: File.rm_rf!(target)

        case File.rename(tmp, target) do
          :ok -> :ok
          # Lost a race against a concurrent installer; its result is equally valid.
          {:error, reason} when reason in [:eexist, :enotempty] -> :ok
          {:error, reason} -> raise "could not move driver into #{target}: #{inspect(reason)}"
        end
      after
        File.rm_rf(tmp)
      end
    end
  end

  defp build(tmp, platform, checksums) do
    downloads = Path.join(tmp, ".downloads")
    File.mkdir_p!(downloads)

    # playwright-core: npm tarball, verified against the npm registry's SRI integrity.
    tgz = Path.join(downloads, "playwright-core.tgz")
    download!(npm_url(), tgz)
    verify!(tgz, checksums.playwright_core)

    :ok =
      :erl_tar.extract(String.to_charlist(tgz), [:compressed, {:cwd, String.to_charlist(tmp)}])

    File.regular?(Path.join([tmp, "package", "cli.js"])) ||
      raise "package/cli.js missing in #{npm_url()}"

    # Node.js: official archive, verified against SHASUMS256.txt. Only node + LICENSE are kept.
    expected = Map.fetch!(checksums.node, platform)
    archive = Path.join(downloads, node_archive(platform))
    download!(node_url(platform), archive)
    verify!(archive, "sha256-hex:" <> expected)
    extract_node!(archive, platform, tmp)

    File.rm_rf!(downloads)
    :ok
  end

  defp extract_node!("" <> archive, "win-" <> _ = platform, tmp) do
    dir = "node-v#{@node_version}-#{platform}"
    files = [~c"#{dir}/node.exe", ~c"#{dir}/LICENSE"]
    {:ok, entries} = :zip.extract(String.to_charlist(archive), [{:file_list, files}, :memory])

    for {name, data} <- entries,
        do: File.write!(Path.join(tmp, Path.basename(List.to_string(name))), data)

    :ok
  end

  defp extract_node!(archive, platform, tmp) do
    dir = "node-v#{@node_version}-#{platform}"
    files = [~c"#{dir}/bin/node", ~c"#{dir}/LICENSE"]

    {:ok, entries} =
      :erl_tar.extract(String.to_charlist(archive), [:compressed, :memory, {:files, files}])

    length(entries) == 2 || raise "unexpected Node.js archive layout in #{archive}"

    for {name, data} <- entries do
      dest = Path.join(tmp, Path.basename(List.to_string(name)))
      File.write!(dest, data)
      if Path.basename(dest) == "node", do: File.chmod!(dest, 0o755)
    end

    :ok
  end

  @doc """
  Installs browsers with the driver's own Node, like `python -m playwright install ...`
  (which forwards its argv to `node cli.js`). No args installs its default browsers, as
  `npx playwright install`. Browsers land in Playwright's usual
  location (`PLAYWRIGHT_BROWSERS_PATH`, default `~/Library/Caches/ms-playwright` etc). The
  output goes to stdout; a failed install returns the CLI's exit status.
  """
  @spec install_browsers([String.t()], [option()]) :: :ok | {:error, {:exit_status, non_neg_integer()}}
  def install_browsers(args \\ [], opts \\ []) do
    {program, prefix} = ensure_installed(opts)

    case System.cmd(program, prefix ++ ["install" | args],
           env: driver_env(),
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, status} -> {:error, {:exit_status, status}}
    end
  end

  # PW_LANG_NAME: not "node" (the driver then replaces lone surrogates, `toWellFormed`); not in
  # the driver's embedder list either, so APIRequestContext's default User-Agent ends in
  # "unknown/unknown" (upstream JS: "node/<version>").
  @doc false
  def driver_env, do: [{"PW_LANG_NAME", "elixir"}, {"PW_CLI_DISPLAY_VERSION", @driver_version}]

  # --- verification -------------------------------------------------------

  @doc false
  # Verifies `path` against `expected`: an npm SRI string (`sha512-<base64>`) or
  # `sha256-hex:<hex>` (nodejs.org SHASUMS256). Raises with a clear message on mismatch.
  def verify!(path, expected) do
    {algo, want} =
      case expected do
        "sha512-" <> b64 -> {:sha512, Base.decode64!(b64)}
        "sha256-hex:" <> hex -> {:sha256, Base.decode16!(hex, case: :mixed)}
      end

    got =
      path
      |> File.stream!(65_536)
      |> Enum.reduce(:crypto.hash_init(algo), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()

    if got != want do
      raise PlaywrightEx.Driver.ChecksumError,
        message: """
        checksum mismatch for #{Path.basename(path)} (#{algo})
          expected: #{Base.encode16(want, case: :lower)}
          got:      #{Base.encode16(got, case: :lower)}
        The download may be corrupted or tampered with. Nothing was installed.\
        """
    end

    :ok
  end

  # --- urls / platform ----------------------------------------------------

  @doc false
  def npm_url, do: "https://registry.npmjs.org/playwright-core/-/playwright-core-#{@driver_version}.tgz"

  @doc false
  def node_archive("win-" <> _ = p), do: "node-v#{@node_version}-#{p}.zip"
  def node_archive(p), do: "node-v#{@node_version}-#{p}.tar.gz"
  @doc false
  def node_url(p), do: "https://nodejs.org/dist/v#{@node_version}/#{node_archive(p)}"

  defp node_path(opts) do
    dir = install_dir(opts)

    if String.starts_with?(Path.basename(dir), "win-"),
      do: Path.join(dir, "node.exe"),
      else: Path.join(dir, "node")
  end

  defp cli_path(opts), do: Path.join([install_dir(opts), "package", "cli.js"])

  @doc false
  # Host platform in nodejs.org naming, or raises for unsupported hosts.
  def platform! do
    case platform() do
      {:ok, p} -> p
      {:error, desc} -> unsupported!(desc)
    end
  end

  defp unsupported!(desc) do
    raise """
    PlaywrightEx cannot download a driver for this platform (#{desc}).
    Supported: #{Enum.join(@platforms, ", ")}.
    Install Playwright yourself (`npm i playwright@#{@driver_version}`) and pass
    `executable: "node_modules/.bin/playwright"` (or set PLAYWRIGHT_EX_EXECUTABLE),
    or point PLAYWRIGHT_NODEJS_PATH at a Node.js binary.\
    """
  end

  @doc false
  def platform do
    arch = :system_architecture |> :erlang.system_info() |> List.to_string()

    {os, cpu} =
      case :os.type() do
        {:win32, _} -> {"win", System.get_env("PROCESSOR_ARCHITECTURE", "")}
        {:unix, :darwin} -> {"darwin", arch}
        {:unix, :linux} -> {"linux", arch}
        {:unix, other} -> {Atom.to_string(other), arch}
      end

    cpu =
      cond do
        cpu =~ ~r/^(x86_64|amd64)/i -> "x64"
        cpu =~ ~r/^(aarch64|arm64)/i -> "arm64"
        true -> cpu
      end

    p = "#{os}-#{cpu}"

    cond do
      # Official Node.js builds are glibc-only (no Alpine/musl), like Playwright itself.
      os == "linux" and Path.wildcard("/lib/ld-musl-*") != [] -> {:error, "#{p} with musl libc"}
      p in @platforms -> {:ok, p}
      true -> {:error, "#{p}, from #{arch}"}
    end
  end

  # --- download (like the esbuild hex package) ------------------------------

  @doc false
  def download!(url, dest) do
    for app <- [:inets, :ssl], do: {:ok, _} = Application.ensure_all_started(app)
    set_proxies(url)

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      autoredirect: true,
      timeout: 600_000,
      connect_timeout: 30_000
    ]

    File.rm(dest)
    request = {String.to_charlist(url), [{~c"user-agent", ~c"playwright_ex/#{@driver_version}"}]}

    case :httpc.request(:get, request, http_opts, stream: String.to_charlist(dest)) do
      {:ok, :saved_to_file} -> :ok
      {:ok, {{_, status, _}, _, _}} -> raise "download of #{url} failed: HTTP #{status}"
      {:error, reason} -> raise "download of #{url} failed: #{inspect(reason)}"
    end
  end

  defp set_proxies(url) do
    scheme = if String.starts_with?(url, "https"), do: :https_proxy, else: :proxy

    var =
      if scheme == :https_proxy,
        do: ["HTTPS_PROXY", "https_proxy"],
        else: ["HTTP_PROXY", "http_proxy"]

    with proxy when is_binary(proxy) <- Enum.find_value(var, &System.get_env/1),
         %URI{host: host, port: port} when is_binary(host) <- URI.parse(proxy) do
      :httpc.set_options([{scheme, {{String.to_charlist(host), port}, []}}])
    end
  end

  defp env(name), do: name |> System.get_env() |> then(&if(&1 in [nil, ""], do: nil, else: &1))
end

defmodule PlaywrightEx.Driver.ChecksumError do
  @moduledoc false
  defexception [:message]
end
