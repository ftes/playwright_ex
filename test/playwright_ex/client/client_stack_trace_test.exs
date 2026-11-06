defmodule PlaywrightEx.Client.ClientStackTraceTest do
  # Every API call captures the stack before its message is sent (`_wrapApiCall`). A
  # `File.cwd!/0` per frame (~50 us each, ms under load) delayed messages that JS writes in the
  # same tick: a `page.close()` right after `void route.continue()` hung in the driver, a worker's
  # `evaluate` missed its console (ISSUES.md #7, #10). The directory is looked up once.
  # Not async: it changes the working directory of the VM.
  use ExUnit.Case, async: false

  alias PlaywrightEx.Client.ClientStackTrace

  @tag :tmp_dir
  test "frames resolve against the working directory of the first capture", %{tmp_dir: tmp_dir} do
    %{frames: [_ | _] = frames} = ClientStackTrace.capture_library_stack_trace()
    assert Enum.all?(frames, &(Path.type(&1.file) == :absolute))
    cwd = File.cwd!()

    try do
      File.cd!(tmp_dir)
      assert ClientStackTrace.capture_library_stack_trace().frames == frames
    after
      File.cd!(cwd)
    end
  end
end
