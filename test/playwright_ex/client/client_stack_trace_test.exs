# Outside `PlaywrightEx.Client.*`: frames of those modules are the library's, not the caller's.
defmodule PlaywrightEx.ClientStackTraceTest do
  # Every API call captures the stack before its message is sent (`_wrapApiCall`). A
  # `File.cwd!/0` per frame (~50 us each, ms under load) delayed messages that JS writes in the
  # same tick: a `page.close()` right after `void route.continue()` hung in the driver, a worker's
  # `evaluate` missed its console. Paths come from the modules' compile info.
  # Not async: it changes the working directory of the VM.
  use ExUnit.Case, async: false

  alias PlaywrightEx.Client.ClientStackTrace

  test "the caller's frame is its module's absolute source" do
    %{frames: [frame | _]} = ClientStackTrace.capture_library_stack_trace()
    assert frame.function =~ "PlaywrightEx.ClientStackTraceTest."
    assert frame.file == __ENV__.file
  end

  @tag :tmp_dir
  test "frames don't depend on the working directory", %{tmp_dir: tmp_dir} do
    files = fn -> Enum.map(ClientStackTrace.capture_library_stack_trace().frames, & &1.file) end
    [_ | _] = before = files.()
    cwd = File.cwd!()

    try do
      File.cd!(tmp_dir)
      assert files.() == before
    after
      File.cd!(cwd)
    end
  end
end
