defmodule PlaywrightEx.PortTransportTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.PortTransport

  @tag :tmp_dir
  test "rejects Playwright versions older than 1.63", %{tmp_dir: tmp_dir} do
    executable = Path.join(tmp_dir, "playwright")
    File.write!(executable, "#!/bin/sh\nprintf 'Version 1.62.1\\n'\n")
    File.chmod!(executable, 0o755)

    assert_raise RuntimeError,
                 "Unsupported Playwright version 1.62.1; PlaywrightEx requires version 1.63.0 or newer",
                 fn ->
                   PortTransport.start_link(executable: executable)
                 end
  end
end
