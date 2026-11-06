defmodule PlaywrightEx.Client.ErrorsTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.Client.Errors

  # Elixir only: the driver's install hints name `mix playwright_ex.install`
  # (architecture: Driver language and rendering).
  describe "rewrite_driver_hints/1" do
    test "rewrites the install command inside the ASCII box, keeping it aligned" do
      box = """
      ╔════════════════════════════════════════════════════════════╗
      ║ Looks like Playwright was just installed or updated.       ║
      ║ Please run the following command to download new browsers: ║
      ║                                                            ║
      ║     npx playwright install                                 ║
      ║                                                            ║
      ║ <3 Playwright Team                                         ║
      ╚════════════════════════════════════════════════════════════╝\
      """

      rewritten = Errors.rewrite_driver_hints(box)
      assert rewritten =~ "║     mix playwright_ex.install                              ║"
      assert rewritten |> String.split("\n") |> Enum.map(&String.length/1) |> Enum.uniq() |> length() == 1
    end

    test "forwards browser args" do
      assert Errors.rewrite_driver_hints(
               ~s(Chromium distribution 'msedge' is not found\nRun "npx playwright install msedge")
             ) ==
               ~s(Chromium distribution 'msedge' is not found\nRun "mix playwright_ex.install -- msedge")
    end

    test "leaves other commands alone" do
      assert Errors.rewrite_driver_hints("    sudo npx playwright install-deps") ==
               "    sudo npx playwright install-deps"

      assert Errors.rewrite_driver_hints("no hint") == "no hint"
    end
  end
end
