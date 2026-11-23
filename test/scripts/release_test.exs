Code.require_file("../../scripts/release.exs", __DIR__)

defmodule ReleaseScript.EditTest do
  use ExUnit.Case, async: true

  alias ReleaseScript.{Edit, Error}

  @driver "Drives [Playwright 1.65.1](https://github.com/microsoft/playwright/releases/tag/v1.65.1), on\nNode 26.13.1."

  @changelog """
  # Changelog

  ## Versioning

  Text.

  ## [Unreleased]

  ### Fixed

  - A fix.

  ## [1.65.0-rc.4] 2026-11-23

  #{@driver} No upstream API changes.

  ### Added

  - A feature.

  ## 0.16 and earlier

  ## [0.16.0] 2026-11-04
  """

  @date ~D[2026-11-24]

  describe "release_heading/3" do
    test "renames the Unreleased heading to the version and date" do
      assert Edit.release_heading(@changelog, "1.65.0-rc.5", @date) ==
               String.replace(@changelog, "## [Unreleased]", "## [1.65.0-rc.5] 2026-11-24")
    end

    test "fails without an Unreleased heading" do
      assert_raise Error, ~r/no `## \[Unreleased\]` heading/, fn ->
        Edit.release_heading("# Changelog\n", "1.0.0", @date)
      end
    end
  end

  # A function, not an attribute: OTP 28 can't store a compiled regex in one.
  defp snippet, do: ~r/\{:playwright, "~> ([^"]+)", hex: :playwright_ex\}/

  describe "bump/3 and set_version/2" do
    test "bumps each snippet and leaves other version requirements alone" do
      readme = """
      {:playwright, "~> 1.65.0-rc.4", hex: :playwright_ex}
      {:playwright, "~> 1.65.0", only: :test}
      Depend on `{:playwright, "~> 1.65.0-rc.4", hex: :playwright_ex}`.
      """

      assert Edit.bump(readme, snippet(), "1.65.0-rc.5") == """
             {:playwright, "~> 1.65.0-rc.5", hex: :playwright_ex}
             {:playwright, "~> 1.65.0", only: :test}
             Depend on `{:playwright, "~> 1.65.0-rc.5", hex: :playwright_ex}`.
             """
    end

    test "requirement/2 takes major.minor.0 for a final version, the full one for a prerelease" do
      assert Edit.requirement("1.65.0", true) == "1.65.0"
      assert Edit.requirement("1.65.3", true) == "1.65.0"
      assert Edit.requirement("1.65.0-rc.5", true) == "1.65.0-rc.5"
      assert Edit.requirement("1.65.3", false) == "1.65.3"
    end

    test "fails when the snippet isn't there" do
      assert_raise Error, ~r/no match/, fn -> Edit.bump("nothing", snippet(), "1.0.0") end
    end

    test "reads and sets @version in mix.exs" do
      mix_exs = ~s(defmodule P.MixProject do\n  @version "1.65.0-rc.4"\n  @other "1.65.0-rc.4"\nend\n)

      assert Edit.current_version(mix_exs) == "1.65.0-rc.4"

      assert Edit.set_version(mix_exs, "1.65.0") ==
               String.replace(mix_exs, ~s(@version "1.65.0-rc.4"), ~s(@version "1.65.0"))
    end
  end

  describe "driver_line/4" do
    test "inserts the driver, with no upstream API changes when the previous release drove it" do
      released = Edit.release_heading(@changelog, "1.65.0-rc.5", @date)

      assert Edit.driver_line(released, "1.65.0-rc.5", "1.65.1", "26.13.1") =~
               "## [1.65.0-rc.5] 2026-11-24\n\n#{@driver} No upstream API changes.\n\n### Fixed\n\n- A fix.\n\n## [1.65.0-rc.4]"
    end

    test "inserts the driver alone when the previous release drove another" do
      released = Edit.release_heading(@changelog, "1.66.0", @date)

      assert Edit.driver_line(released, "1.66.0", "1.66.0", "26.14.0") =~
               "## [1.66.0] 2026-11-24\n\n" <>
                 "Drives [Playwright 1.66.0](https://github.com/microsoft/playwright/releases/tag/v1.66.0), on\n" <>
                 "Node 26.14.0.\n\n### Fixed"
    end

    test "keeps a driver line the section has" do
      changelog = String.replace(@changelog, "### Fixed", "Drives [Playwright 1.66.0](url).\n\n### Fixed")
      released = Edit.release_heading(changelog, "1.66.0", @date)

      assert Edit.driver_line(released, "1.66.0", "1.66.0", "26.14.0") == released
    end
  end

  test "start_next/2 inserts an empty Unreleased above the release" do
    released = Edit.release_heading(@changelog, "1.65.0-rc.5", @date)

    assert Edit.start_next(released, "1.65.0-rc.5") ==
             String.replace(@changelog, "## [Unreleased]", "## [Unreleased]\n\n## [1.65.0-rc.5] 2026-11-24")
  end

  describe "guards" do
    test "unreleased_content?/1" do
      assert Edit.unreleased_content?(@changelog)
      refute Edit.unreleased_content?(String.replace(@changelog, "### Fixed\n\n- A fix.\n\n", ""))
      refute Edit.unreleased_content?("## [Unreleased]\n\n  \n")
    end

    test "newer?/2 compares SemVer, prereleases first" do
      assert Edit.newer?("1.65.0-rc.5", "1.65.0-rc.4")
      assert Edit.newer?("1.65.0-rc.10", "1.65.0-rc.9")
      assert Edit.newer?("1.65.0", "1.65.0-rc.5")
      refute Edit.newer?("1.65.0-rc.4", "1.65.0-rc.4")
      refute Edit.newer?("1.65.0-rc.3", "1.65.0-rc.4")
    end

    test "rc_sections?/2 finds a final version's prerelease sections" do
      refute Edit.rc_sections?(@changelog, "1.65.0-rc.5")
      assert Edit.rc_sections?(@changelog, "1.65.0")
      refute Edit.rc_sections?(@changelog, "1.65.1")
      refute Edit.rc_sections?(String.replace(@changelog, "## [1.65.0-rc.4] 2026-11-23", "## [1.64.0]"), "1.65.0")
    end

    test "same_minor?/2 compares the driver's major.minor" do
      assert Edit.same_minor?("1.65.0-rc.5", "1.65.1")
      assert Edit.same_minor?("1.65.3", "1.65.0")
      refute Edit.same_minor?("1.65.0", "1.66.0")
      refute Edit.same_minor?("1.65.0", "2.65.0")
      refute Edit.same_minor?("1.65.0", "garbage")
    end

    test "parse_version/1 takes SemVer only" do
      assert Edit.parse_version("1.65.0-rc.5") == "1.65.0-rc.5"
      assert_raise Error, ~r/not a SemVer version/, fn -> Edit.parse_version("v1.65.0") end
      assert_raise Error, ~r/not a SemVer version/, fn -> Edit.parse_version("1.65") end
    end
  end
end
