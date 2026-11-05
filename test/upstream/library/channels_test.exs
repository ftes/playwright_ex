defmodule PlaywrightEx.Library.ChannelsTest do
  @upstream "tests/library/channels.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page
  alias PlaywrightEx.WebSocket

  # expectScopeState compares the client's and the server's (toImplInWorkerScope) object trees.

  test "should scope context handles"

  test "should scope CDPSession handles"

  test "should scope browser handles"

  test "should not generate dispatchers for subresources w/o listeners"

  test "should work with the domain module", %{browser_type: browser_type, server: server} do
    # Node's `domain` module (catching stray 'error' events) is JS-only: the rest is ported.
    browser = BrowserType.launch!(browser_type)
    page = Browser.new_page!(browser)

    assert Page.evaluate!(page, "() => 1 + 1") == 2

    # At the time of writing, we used to emit 'error' event for WebSockets,
    # which failed with 'domain' module.
    me = self()
    Page.on(page, :web_socket, fn ws -> WebSocket.on(ws, :socket_error, &send(me, {:socket_error, &1})) end)

    Page.evaluate!(
      page,
      """
      host => {
        new WebSocket('ws://' + host + '/bogus-ws');
      }
      """,
      server.host
    )

    assert_receive {:socket_error, message}, 5000
    # channel?.includes('msedge') ? '' : ': 400'
    assert message =~ ": 400"

    Browser.close!(browser)
  end

  test "exposeFunction should not leak"
end
