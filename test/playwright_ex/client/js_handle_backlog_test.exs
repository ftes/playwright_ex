defmodule PlaywrightEx.Client.JSHandleBacklogTest do
  # Not mirrored from upstream (OTP_BACKLOG): when one of the `exposeBinding` calls for function
  # arguments rejects, the others leave no result message in the caller's mailbox.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  test "a rejected function argument leaves no messages behind", %{context: context} do
    page = PlaywrightEx.BrowserContext.new_page!(context)
    Page.close!(page)

    for _ <- 1..20 do
      assert {:error, _} = Page.evaluate(page, "([a, b, c]) => a", [fn -> 1 end, fn -> 2 end, fn -> 3 end])
    end

    Process.sleep(200)
    assert {:messages, []} = Process.info(self(), :messages)
  end
end
