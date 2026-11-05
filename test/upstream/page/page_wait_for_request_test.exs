defmodule PlaywrightEx.Page.PageWaitForRequestTest do
  @upstream "tests/page/page-wait-for-request.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request
  alias PlaywrightEx.TimeoutError

  @moduletag :page

  @fetch_digits """
  () => {
    void fetch('/digits/1.png');
    void fetch('/digits/2.png');
    void fetch('/digits/3.png');
  }
  """

  test "should work", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    request =
      Page.expect_request!(page, server.prefix <> "/digits/2.png", fn -> Page.evaluate!(page, @fetch_digits) end)

    assert Request.url(request) == server.prefix <> "/digits/2.png"
  end

  test "should work with predicate", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    promise = Page.wait_for_event(page, :request, &(Request.url(&1) == server.prefix <> "/digits/2.png"))
    Page.evaluate!(page, @fetch_digits)
    request = Promise.await!(promise)
    assert Request.url(request) == server.prefix <> "/digits/2.png"
  end

  test "should respect timeout", %{page: page} do
    {error, stacktrace} =
      try do
        page |> Page.wait_for_event(:request, predicate: fn _ -> false end, timeout: 1) |> Promise.await!()
        {nil, nil}
      rescue
        e -> {e, __STACKTRACE__}
      end

    assert %TimeoutError{} = error
    assert Exception.message(error) =~ ~s(Timeout 1ms exceeded while waiting for event "request")
    # Error stack should point to the api call (error.stack: the Elixir stacktrace).
    assert Exception.format(:error, error, stacktrace) =~ Path.relative_to_cwd(__ENV__.file)
  end

  test "should respect default timeout", %{page: page} do
    Page.set_default_timeout(page, 1)
    # `waitForEvent('request', () => false)`: the predicate is an option.
    {:error, error} = page |> Page.wait_for_event(:request, fn _ -> false end) |> Promise.await()
    assert %TimeoutError{} = error
  end

  test "should log the url", %{page: page} do
    {:error, error} =
      page
      |> Page.wait_for_request(
        "long-long-long-long-long-long-long-long-long-long-long-long-long-long.css",
        timeout: 1000
      )
      |> Promise.await()

    assert Exception.message(error) =~ ~s(waiting for request "long-long-long-long-long-long-long-long-long-long…")
  end

  test "should work with no timeout", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    request =
      Page.expect_request!(
        page,
        server.prefix <> "/digits/2.png",
        fn ->
          Page.evaluate!(page, """
          () => window.builtins.setTimeout(() => {
            void fetch('/digits/1.png');
            void fetch('/digits/2.png');
            void fetch('/digits/3.png');
          }, 50)
          """)
        end,
        timeout: 0
      )

    assert Request.url(request) == server.prefix <> "/digits/2.png"
  end

  test "should work with url match", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    promise = Page.wait_for_request(page, ~r/digits\/\d\.png/)
    Page.evaluate!(page, "() => { void fetch('/digits/1.png'); }")
    assert Request.url(Promise.await!(promise)) == server.prefix <> "/digits/1.png"
  end

  # `vm.runInContext('new RegExp(...)')`: a regex compiled at runtime.
  test "should work with url match regular expression from a different context", %{page: page, server: server} do
    regexp = Regex.compile!("digits\\/\\d\\.png")
    Page.goto!(page, server.empty_page)
    promise = Page.wait_for_request(page, regexp)
    Page.evaluate!(page, "() => { void fetch('/digits/1.png'); }")
    assert Request.url(Promise.await!(promise)) == server.prefix <> "/digits/1.png"
  end
end
