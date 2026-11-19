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

    test "doesn't reinstall the driver when upstream installs nothing" do
      for flag <- ~w(--dry-run --list --help -h) do
        assert Install.parse_args(["--force", "chromium", flag]) == {true, false, ["--force", "chromium", flag]}
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

    test "everything after a -- is forwarded untouched" do
      assert {true, false, ~w(-- chromium)} = Install.parse_args(~w(-- chromium))
      assert {true, true, ~w(--force -- --force --dry-run)} = Install.parse_args(~w(--force -- --force --dry-run))
      assert {true, true, ~w(--force -- --list)} = Install.parse_args(~w(--force -- --list))
      assert {false, true, []} = Install.parse_args(~w(--force --no-browsers))

      assert_raise Mix.Error, ~r/got: -- chromium$/, fn -> Install.parse_args(~w(--no-browsers -- chromium)) end
      assert_raise Mix.Error, ~r/got: --$/, fn -> Install.parse_args(~w(--no-browsers --)) end
    end
  end

  test "a failed browser install raises with the exit status" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/^playwright install failed with exit status [1-9]/, fn ->
          Install.run(["no-such-browser"])
        end
      end)

    assert output =~ "no-such-browser"
  end
end
