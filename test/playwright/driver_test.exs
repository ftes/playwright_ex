defmodule Playwright.DriverTest do
  use ExUnit.Case, async: true

  alias Playwright.Driver

  @moduletag :tmp_dir

  test "ensure_installed/1 installs once, then is a no-op" do
    {node, [cli]} = Driver.ensure_installed()
    assert File.regular?(node)
    assert File.regular?(cli)

    {us, _} = :timer.tc(fn -> Driver.ensure_installed() end)
    # A no-op: installing downloads for seconds. Generous bound for loaded machines.
    assert us < 500_000
  end

  test "tampered download: clear error, nothing installed", %{tmp_dir: cache} do
    bad = put_in(Driver.checksums().playwright_core, "sha512-" <> Base.encode64(:binary.copy(<<0>>, 64)))

    error = assert_raise Driver.ChecksumError, fn -> Driver.install(cache_dir: cache, checksums: bad) end
    assert error.message =~ "checksum mismatch for playwright-core.tgz"
    assert File.ls!(Path.join(cache, Driver.version())) == []
    refute Driver.installed?(cache_dir: cache)
  end

  test "a broken install (cli.js missing) is not installed, and is reinstalled", %{tmp_dir: cache} do
    File.mkdir_p!(Path.join(Driver.install_dir(cache_dir: cache), "package"))
    File.write!(Path.join(Driver.install_dir(cache_dir: cache), "node"), "")
    refute Driver.installed?(cache_dir: cache)

    # The reinstall is attempted: it fails at the (tampered) checksum here.
    bad = put_in(Driver.checksums().playwright_core, "sha512-" <> Base.encode64(:binary.copy(<<0>>, 64)))
    assert_raise Driver.ChecksumError, fn -> Driver.ensure_installed(cache_dir: cache, checksums: bad) end
  end

  test "verify!/2 checks sha256 hex digests", %{tmp_dir: tmp} do
    file = Path.join(tmp, "node.tar.gz")
    File.write!(file, "not really node")

    assert_raise Driver.ChecksumError, ~r/sha256/, fn ->
      Driver.verify!(file, "sha256-hex:" <> Driver.checksums().node["darwin-arm64"])
    end

    assert :ok = Driver.verify!(file, "sha256-hex:" <> Base.encode16(:crypto.hash(:sha256, "not really node")))
  end

  test "overrides and unsupported platforms", %{tmp_dir: cache} do
    assert {"/opt/pw/playwright", []} = Driver.executable(executable: "/opt/pw/playwright")
    assert {"/usr/local/bin/node", [cli]} = Driver.executable(node: "/usr/local/bin/node", cache_dir: "/c")
    assert String.ends_with?(cli, "/package/cli.js")
    assert {:ok, _} = Driver.platform()

    assert_raise RuntimeError, ~r/expected one of darwin-arm64/, fn ->
      Driver.install(platform: "freebsd-x64", checksums: %{Driver.checksums() | node: %{}}, cache_dir: cache)
    end
  end
end

defmodule Playwright.DriverConfigTest do
  # Not async: the app env is global.
  use ExUnit.Case, async: false

  alias Playwright.Driver

  setup do
    previous = Application.fetch_env(:playwright, :driver)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:playwright, :driver, config)
        :error -> Application.delete_env(:playwright, :driver)
      end
    end)
  end

  test "config :playwright, :driver sets the options' defaults" do
    Application.put_env(:playwright, :driver, cache_dir: "/c", node: "/usr/local/bin/node")
    assert Driver.cache_dir() == "/c"
    assert Driver.cache_dir(cache_dir: "/d") == "/d"
    assert {"/usr/local/bin/node", ["/c/" <> _]} = Driver.executable()
    # An empty value (an empty env var read in config) counts as unset.
    assert Driver.cache_dir(cache_dir: "") == "/c"
    Application.put_env(:playwright, :driver, cache_dir: "")
    assert Driver.cache_dir() == Driver.cache_dir(cache_dir: nil)
    refute Driver.cache_dir() == ""

    Application.put_env(:playwright, :driver, cachedir: "/c")

    assert_raise ArgumentError,
                 "config :playwright, :driver: unknown keys, expected one of [:executable, :node, :cache_dir], got: [:cachedir]",
                 fn ->
                   Driver.cache_dir()
                 end
  end
end
