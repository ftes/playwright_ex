defmodule PlaywrightEx.Page.PageWaitForResponseTest do
  @upstream "tests/page/page-wait-for-response.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Response
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
    promise = Page.wait_for_response(page, server.prefix <> "/digits/2.png")
    Page.evaluate!(page, @fetch_digits)
    assert Response.url(Promise.await!(promise)) == server.prefix <> "/digits/2.png"
  end

  test "should respect timeout", %{page: page} do
    {:error, error} =
      page |> Page.wait_for_event(:response, predicate: fn _ -> false end, timeout: 1) |> Promise.await()

    assert %TimeoutError{} = error
  end

  test "should respect default timeout", %{page: page} do
    Page.set_default_timeout(page, 1)
    {:error, error} = page |> Page.wait_for_response(fn _ -> false end) |> Promise.await()
    assert %TimeoutError{} = error
    # Error stack should point to the api call.  -- not ported: Elixir exceptions carry no JS stack
  end

  test "should log the url", %{page: page} do
    {:error, error1} = page |> Page.wait_for_response("foo.css", timeout: 1000) |> Promise.await()
    assert Exception.message(error1) =~ ~s(waiting for response "foo.css")
    {:error, error2} = page |> Page.wait_for_response(~r/foo.css/i, timeout: 1000) |> Promise.await()
    assert Exception.message(error2) =~ "waiting for response /foo.css/i"
  end

  test "should work with predicate", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    response =
      Page.expect_event!(page, :response, fn -> Page.evaluate!(page, @fetch_digits) end,
        predicate: &(Response.url(&1) == server.prefix <> "/digits/2.png")
      )

    assert Response.url(response) == server.prefix <> "/digits/2.png"
  end

  test "should work with async predicate", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    promise1 =
      Page.wait_for_event(page, :response,
        predicate: fn response -> Response.text!(response) =~ "contents of the file" end
      )

    promise2 = Page.wait_for_response(page, fn response -> Response.text!(response) =~ "bar" end)

    Page.evaluate!(page, """
    () => {
      void fetch('/simple.json').then(r => r.json());
      void fetch('/file-to-upload.txt').then(r => r.text());
    }
    """)

    assert Response.url(Promise.await!(promise1)) == server.prefix <> "/file-to-upload.txt"
    assert Response.url(Promise.await!(promise2)) == server.prefix <> "/simple.json"
  end

  test "sync predicate should be only called once", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    promise =
      Page.wait_for_event(page, :response,
        predicate: fn response ->
          Agent.update(counter, &(&1 + 1))
          Response.url(response) == server.prefix <> "/digits/1.png"
        end
      )

    Page.evaluate!(page, """
    async () => {
      await fetch('/digits/1.png');
      await fetch('/digits/2.png');
      await fetch('/digits/3.png');
    }
    """)

    assert Response.url(Promise.await!(promise)) == server.prefix <> "/digits/1.png"
    assert Agent.get(counter, & &1) == 1
  end

  test "should work with no timeout", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)

    response =
      Page.expect_response!(
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

    assert Response.url(response) == server.prefix <> "/digits/2.png"
  end
end
