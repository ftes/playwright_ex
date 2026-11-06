defmodule PlaywrightEx.Page.NetworkPostDataTest do
  @upstream "tests/page/network-post-data.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Request

  @moduletag :page

  @browser_name System.get_env("BROWSER", "chromium")

  test "should return correct postData buffer for utf-8 body", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    value = "baẞ"
    request = Page.wait_for_request(page, "**")

    Page.evaluate!(
      page,
      """
      ({ url, value }) => {
        const request = new Request(url, {
          method: 'POST',
          body: JSON.stringify(value),
        });
        request.headers.set('content-type', 'application/json;charset=UTF-8');
        return fetch(request);
      }
      """,
      %{url: server.prefix <> "/title.html", value: value}
    )

    request = Promise.await!(request)
    assert Request.post_data_buffer(request) == JSON.encode!(value)
    assert Request.post_data_json(request) == value
  end

  test "should return post data w/o content-type @smoke", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request = Page.wait_for_request(page, "**")

    Page.evaluate!(
      page,
      """
      ({ url }) => {
        const request = new Request(url, {
          method: 'POST',
          body: JSON.stringify({ value: 42 }),
        });
        request.headers.set('content-type', '');
        return fetch(request);
      }
      """,
      %{url: server.prefix <> "/title.html"}
    )

    request = Promise.await!(request)
    assert Request.post_data_json(request) == %{"value" => 42}
  end

  test "should throw on invalid JSON in post data", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request = Page.wait_for_request(page, "**")

    Page.evaluate!(
      page,
      """
      ({ url }) => {
        const request = new Request(url, {
          method: 'POST',
          body: '<not a json>',
        });
        return fetch(request);
      }
      """,
      %{url: server.prefix <> "/title.html"}
    )

    request = Promise.await!(request)
    error = assert_raise RuntimeError, fn -> Request.post_data_json(request) end
    assert Exception.message(error) =~ "POST data is not a valid JSON object: <not a json>"
  end

  test "should return post data for PUT requests", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    request = Page.wait_for_request(page, "**")

    Page.evaluate!(
      page,
      """
      ({ url }) => {
        const request = new Request(url, {
          method: 'PUT',
          body: JSON.stringify({ value: 42 }),
        });
        return fetch(request);
      }
      """,
      %{url: server.prefix <> "/title.html"}
    )

    request = Promise.await!(request)
    assert Request.post_data_json(request) == %{"value" => 42}
  end

  test "should get post data for file/blob", %{page: page, server: server} do
    # it.fail(browserName === 'webkit' || browserName === 'chromium')
    expected_failure(@browser_name in ["webkit", "chromium"], fn ->
      Page.goto!(page, server.empty_page)
      request = Page.wait_for_request(page, "**/*")

      Page.evaluate!(page, """
      () => {
        const file = new File(['file-contents'], 'filename.txt');

        void fetch('/data', {
          method: 'POST',
          headers: {
            'content-type': 'application/octet-stream'
          },
          body: file
        });
      }
      """)

      request = Promise.await!(request)
      assert Request.post_data(request) == "file-contents"
    end)
  end

  test "should get post data for navigator.sendBeacon api calls", %{page: page, server: server} do
    # it.fail(chromium); it.fail(webkit): postData is empty
    expected_failure(@browser_name in ["chromium", "webkit"], fn ->
      # it.info().annotations.push({ type: 'issue', description: 'https://github.com/microsoft/playwright/issues/12231' });
      Page.goto!(page, server.empty_page)
      request = Page.wait_for_request(page, "**/*")

      Page.evaluate!(
        page,
        "() => navigator.sendBeacon(window.location.origin + '/api/foo', new Blob([JSON.stringify({ foo: 'bar' })]))"
      )

      request = Promise.await!(request)
      assert Request.method(request) == "POST"
      assert Request.url(request) == server.prefix <> "/api/foo"
      assert Request.post_data_json(request) == %{"foo" => "bar"}
    end)
  end
end
