defmodule Mix.Tasks.Playwright.InstallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Playwright.Install

  describe "parse_args/1" do
    test "forwards positionals and upstream's flags in order" do
      assert Install.parse_args([]) == {[browsers: true, force: false], []}

      assert Install.parse_args(~w(chromium firefox --with-deps)) ==
               {[browsers: true, force: false], ~w(chromium firefox --with-deps)}

      assert Install.parse_args(~w(--with-deps chromium --dry-run)) ==
               {[browsers: true, force: false], ~w(--with-deps chromium --dry-run)}
    end

    test "forwards a --, and what follows" do
      assert Install.parse_args(~w(-- chromium --with-deps)) ==
               {[browsers: true, force: false], ~w(-- chromium --with-deps)}

      assert Install.parse_args(~w(chromium -- --)) == {[browsers: true, force: false], ~w(chromium -- --)}
    end

    test "takes --force before a --, in any position, and forwards it" do
      assert Install.parse_args(~w(chromium --force --with-deps)) ==
               {[browsers: true, force: true], ~w(chromium --force --with-deps)}

      assert Install.parse_args(~w(--force -- chromium)) == {[browsers: true, force: true], ~w(--force -- chromium)}
    end

    test "leaves a --force after a -- to upstream" do
      assert Install.parse_args(~w(-- --force chromium)) == {[browsers: true, force: false], ~w(-- --force chromium)}
    end

    test "doesn't reinstall the driver when upstream installs nothing" do
      for flag <- ~w(--dry-run --list --help -h) do
        assert Install.parse_args(["--force", flag]) == {[browsers: true, force: false], ["--force", flag]}
      end
    end

    test "takes --no-browsers, alone or with --force" do
      assert Install.parse_args(~w(--no-browsers)) == {[browsers: false, force: false], []}
      assert Install.parse_args(~w(--force --no-browsers --force)) == {[browsers: false, force: true], []}
    end

    test "--no-browsers with browser args raises, naming them" do
      assert_raise Mix.Error, ~r/--no-browsers .* no browser args, got: chromium --with-deps$/, fn ->
        Install.parse_args(~w(chromium --no-browsers --with-deps))
      end

      assert_raise Mix.Error, ~r/got: -- --force$/, fn -> Install.parse_args(~w(--no-browsers -- --force)) end
      assert_raise Mix.Error, ~r/got: --browsers$/, fn -> Install.parse_args(~w(--no-browsers --browsers)) end
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
