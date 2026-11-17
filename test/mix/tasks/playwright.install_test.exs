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

    test "takes --force in any position, and forwards it" do
      assert Install.parse_args(~w(chromium --force --with-deps)) ==
               {[browsers: true, force: true], ~w(chromium --force --with-deps)}

      assert Install.parse_args(~w(--force)) == {[browsers: true, force: true], ~w(--force)}
    end

    test "takes --no-browsers, alone or with --force" do
      assert Install.parse_args(~w(--no-browsers)) == {[browsers: false, force: false], []}
      assert Install.parse_args(~w(--force --no-browsers)) == {[browsers: false, force: true], ~w(--force)}
    end

    test "takes the default --browsers, without forwarding it" do
      assert Install.parse_args(~w(--browsers chromium)) == {[browsers: true, force: false], ~w(chromium)}
      assert Install.parse_args(~w(--browsers -- chromium)) == {[browsers: true, force: false], ~w(chromium)}
    end

    test "--no-browsers with browser args raises" do
      assert_raise Mix.Error, ~r/--no-browsers .* no browser args, got: chromium --with-deps$/, fn ->
        Install.parse_args(~w(chromium --no-browsers --with-deps))
      end

      assert_raise Mix.Error, ~r/got: chromium$/, fn -> Install.parse_args(~w(--no-browsers -- chromium)) end
      assert_raise Mix.Error, ~r/got: chromium$/, fn -> Install.parse_args(~w(--force chromium --no-browsers)) end
    end

    test "drops a legacy --, forwarding what follows as it is" do
      assert Install.parse_args(~w(-- chromium --with-deps)) ==
               {[browsers: true, force: false], ~w(chromium --with-deps)}

      assert Install.parse_args(~w(--force -- chromium)) == {[browsers: true, force: true], ~w(--force chromium)}
      assert Install.parse_args(~w(chromium -- --force --)) == {[browsers: true, force: false], ~w(chromium --force --)}
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
