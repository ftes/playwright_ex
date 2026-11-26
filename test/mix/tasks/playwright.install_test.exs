defmodule Mix.Tasks.Playwright.InstallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Playwright.Install

  describe "parse_args/1" do
    test "forwards positionals and upstream's flags in order" do
      assert Install.parse_args([]) == {true, false, []}
      assert Install.parse_args(~w(chromium firefox --with-deps)) == {true, false, ~w(chromium firefox --with-deps)}

      assert Install.parse_args(~w(--with-deps chromium --only-shell)) ==
               {true, false, ~w(--with-deps chromium --only-shell)}
    end

    test "takes --force in any position, and forwards it" do
      assert Install.parse_args(~w(chromium --force --with-deps)) == {true, true, ~w(chromium --force --with-deps)}
      assert Install.parse_args(~w(--force)) == {true, true, ~w(--force)}
    end

    test "--force reinstalls the driver whatever else is given" do
      for flag <- ~w(--dry-run --list --help -h) do
        assert Install.parse_args(["--force", "chromium", flag]) == {true, true, ["--force", "chromium", flag]}
      end
    end

    test "takes --no-browsers, alone or with --force" do
      assert Install.parse_args(~w(--no-browsers)) == {false, false, []}
      assert Install.parse_args(~w(--force --no-browsers --force)) == {false, true, []}
    end

    test "--no-browsers with other args raises, naming them" do
      assert_raise Mix.Error, ~r/--no-browsers .* takes no other args, got: chromium --with-deps$/, fn ->
        Install.parse_args(~w(chromium --no-browsers --with-deps))
      end

      assert_raise Mix.Error, ~r/got: --dry-run$/, fn -> Install.parse_args(~w(--force --no-browsers --dry-run)) end
    end

    test "a -- is forwarded" do
      assert {true, false, ~w(-- chromium)} = Install.parse_args(~w(-- chromium))
    end
  end

  test "a failed browser install raises with the exit status" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error,
                     ~r/^Playwright.Driver.install_browsers\/2: playwright install failed, expected exit status 0, got: [1-9]/,
                     fn ->
                       Install.run(["no-such-browser"])
                     end
      end)

    assert output =~ "no-such-browser"
  end
end

defmodule Mix.Tasks.Playwright.InstallExecutableTest do
  # Not async: the app env is global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Playwright.Install

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env(:playwright, :driver)

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:playwright, :driver, config)
        :error -> Application.delete_env(:playwright, :driver)
      end
    end)

    cli = Path.join(tmp, "playwright")
    File.write!(cli, "#!/bin/sh\necho \"fake cli: $*\"\n")
    File.chmod!(cli, 0o755)
    cache = Path.join(tmp, "cache")
    Application.put_env(:playwright, :driver, executable: cli, cache_dir: cache)
    %{cli: cli, cache: cache}
  end

  test "with executable: downloads nothing and installs the browsers with that CLI", %{cli: cli, cache: cache} do
    output = capture_io(fn -> Install.run(~w(chromium --with-deps)) end)

    assert output =~ "No driver to install: config :playwright, :driver sets executable: #{cli}"
    assert output =~ "fake cli: install chromium --with-deps"
    refute File.exists?(cache)
  end

  test "with executable: and --no-browsers does nothing", %{cache: cache} do
    output = capture_io(fn -> Install.run(~w(--no-browsers)) end)

    assert output =~ "No driver to install"
    refute output =~ "fake cli"
    refute File.exists?(cache)
  end
end
