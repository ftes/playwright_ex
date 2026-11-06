defmodule PlaywrightEx.Matchers.MatcherCleanupTest do
  # Not mirrored from upstream: a matcher that times out leaves no messages in the caller's
  # mailbox and no process-local objects in its dictionary (OTP runtime).
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Page

  @moduletag :page

  defp local_objects, do: for({{:pw_local, _}, _} <- Process.get(), do: :local)

  test "a timed-out locator matcher leaves no messages behind", %{page: page} do
    Page.set_content!(page, "<div>foo</div>")
    assert {:error, _} = Expect.to_have_text(Page.locator(page, "div"), "bar", timeout: 200)
    assert {:messages, []} = Process.info(self(), :messages)
    assert local_objects() == []
  end

  test "a timed-out toHaveURL leaves no messages or local objects behind", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert {:error, _} = Expect.to_have_url(page, "/nope", timeout: 200)
    assert {:error, _} = Expect.to_have_url(page, fn _url -> false end, timeout: 200)
    assert {:error, _} = Expect.to_have_url(page, ~r/nope/, timeout: 200, ignore_case: true)
    :ok = Expect.to_have_url!(page, server.empty_page)
    assert {:messages, []} = Process.info(self(), :messages)
    assert local_objects() == []
  end
end
