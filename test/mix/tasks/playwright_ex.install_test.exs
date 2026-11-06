defmodule Mix.Tasks.PlaywrightEx.InstallTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "a failed browser install raises with the exit status" do
    output =
      capture_io(fn ->
        assert_raise Mix.Error, ~r/^playwright install failed with exit status [1-9]/, fn ->
          Mix.Tasks.PlaywrightEx.Install.run(["--", "no-such-browser"])
        end
      end)

    assert output =~ "no-such-browser"
  end
end
