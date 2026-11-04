defmodule Playwright.Transport.Protocol.FrameExpectOptions do
  @moduledoc "upstream: Transport/Protocol/FrameExpectOptions.cs (hand-written, non-nullable float/bool default 0/false)"
  defstruct expression_arg: nil,
            expected_text: nil,
            expected_number: 0,
            expected_value: nil,
            use_inner_text: false,
            is_not: false,
            timeout: nil
end

defmodule Playwright.Transport.Protocol.FrameExpectResult do
  @moduledoc "upstream: Transport/Protocol/FrameExpectResult.cs"
  defstruct matches: false, received: nil, received_aria_snapshot: nil, log: nil, error_message: nil
end
