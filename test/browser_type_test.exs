defmodule PlaywrightEx.BrowserTypeTest do
  use ExUnit.Case, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Frame

  @timeout Application.compile_env(:playwright_ex, :timeout, 5000)

  describe "launch_persistent_context/2" do
    test "launches a persistent context with a user data directory" do
      user_data_dir = Path.join(System.tmp_dir!(), "pw_ex_test_#{System.unique_integer([:positive])}")

      try do
        assert {:ok, context} =
                 PlaywrightEx.launch_persistent_context(:chromium,
                   user_data_dir: user_data_dir,
                   timeout: @timeout
                 )

        # Ensure the returned context structure is correct (mimics new_context/2 return shape)
        assert %{guid: _, tracing: %{guid: _}} = context

        # Ensure the context is functional by creating a page and navigating
        assert {:ok, page} = BrowserContext.new_page(context.guid, timeout: @timeout)
        assert {:ok, _} = Frame.goto(page.main_frame.guid, url: "about:blank", timeout: @timeout)

        # Close the context
        assert {:ok, _} = BrowserContext.close(context.guid, timeout: @timeout)

        # Ensure Playwright actually wrote to the provided user data dir
        assert File.exists?(user_data_dir)
      after
        File.rm_rf(user_data_dir)
      end
    end
  end

  describe "connect_over_cdp/2" do
    test "sends the CDP connection request to Playwright" do
      # We cannot easily stand up a CDP endpoint in this test suite without complex setup,
      # but we can verify that the protocol command is successfully dispatched
      # and handled by Playwright (which will gracefully reject the invalid endpoint).
      result =
        PlaywrightEx.connect_over_cdp(:chromium,
          endpoint_url: "ws://localhost:9999/invalid-cdp-endpoint",
          timeout: @timeout
        )

      assert {:error, %{error: %{message: error_message}}} = result

      # The error should confirm that the JS server attempted the method and connection
      assert error_message =~ "browserType.connectOverCDP" or error_message =~ "connect ECONNREFUSED"
    end
  end
end
