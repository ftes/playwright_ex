defmodule PlaywrightEx.Examples.APIRequestContextTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.{APIRequest, APIRequestContext}

  example "APIRequestContext.addCookies",
    js: ~S"""
    await request.addCookies([cookieObject1, cookieObject2]);
    """,
    given: [
      request: BrowserContext.request(context),
      cookie_object1: %{name: "session-id", value: "1234", url: "https://example.com"},
      cookie_object2: %{name: "theme", value: "dark", domain: "example.com", path: "/"}
    ] do
    APIRequestContext.add_cookies!(request, [cookie_object1, cookie_object2])
  end

  example "APIRequestContext.clearCookies",
    js: ~S"""
    await request.clearCookies();
    await request.clearCookies({ name: 'session-id' });
    await request.clearCookies({ domain: 'my-origin.com' });
    await request.clearCookies({ domain: /.*my-origin\.com/ });
    await request.clearCookies({ path: '/api/v1' });
    await request.clearCookies({ name: 'session-id', domain: 'my-origin.com' });
    """,
    given: [request: BrowserContext.request(context)] do
    APIRequestContext.clear_cookies!(request)
    APIRequestContext.clear_cookies!(request, name: "session-id")
    APIRequestContext.clear_cookies!(request, domain: "my-origin.com")
    APIRequestContext.clear_cookies!(request, domain: ~r/.*my-origin\.com/)
    APIRequestContext.clear_cookies!(request, path: "/api/v1")
    APIRequestContext.clear_cookies!(request, name: "session-id", domain: "my-origin.com")
  end

  example "APIRequestContext.fetch",
    js: ~S"""
    await request.fetch('https://example.com/api/createBook', {
      method: 'post',
      data: {
        title: 'Book Title',
        author: 'John Doe',
      }
    });
    """,
    given: [request: offline_request(playwright)] do
    APIRequestContext.fetch!(request, "https://example.com/api/createBook",
      method: "post",
      data: %{title: "Book Title", author: "John Doe"}
    )
  end

  example "APIRequestContext.fetch",
    js: ~S"""
    const form = new FormData();
    form.set('name', 'John');
    form.append('name', 'Doe');
    // Send two file fields with the same name.
    form.append('file', new File(['console.log(2024);'], 'f1.js', { type: 'text/javascript' }));
    form.append('file', new File(['hello'], 'f2.txt', { type: 'text/plain' }));
    await request.fetch('https://example.com/api/uploadForm', {
      multipart: form
    });
    """,
    given: [request: offline_request(playwright)] do
    form = [
      name: "John",
      name: "Doe",
      # Send two file fields with the same name.
      file: %{name: "f1.js", mimeType: "text/javascript", buffer: "console.log(2024);"},
      file: %{name: "f2.txt", mimeType: "text/plain", buffer: "hello"}
    ]

    APIRequestContext.fetch!(request, "https://example.com/api/uploadForm", multipart: form)
  end

  example "APIRequestContext.get",
    js: ~S"""
    // Passing params as object
    await request.get('https://example.com/api/getText', {
      params: {
        'isbn': '1234',
        'page': 23,
      }
    });

    // Passing params as URLSearchParams
    const searchParams = new URLSearchParams();
    searchParams.set('isbn', '1234');
    searchParams.append('page', 23);
    searchParams.append('page', 24);
    await request.get('https://example.com/api/getText', { params: searchParams });

    // Passing params as string
    const queryString = 'isbn=1234&page=23&page=24';
    await request.get('https://example.com/api/getText', { params: queryString });
    """,
    given: [request: offline_request(playwright)] do
    # Passing params as map
    APIRequestContext.get!(request, "https://example.com/api/getText", params: %{"isbn" => "1234", "page" => 23})

    # Passing params as keyword list (URLSearchParams, names may repeat)
    search_params = [isbn: "1234", page: 23, page: 24]
    APIRequestContext.get!(request, "https://example.com/api/getText", params: search_params)

    # Passing params as string
    query_string = "isbn=1234&page=23&page=24"
    APIRequestContext.get!(request, "https://example.com/api/getText", params: query_string)
  end

  example "APIRequestContext.post",
    js: ~S"""
    await request.post('https://example.com/api/createBook', {
      data: {
        title: 'Book Title',
        author: 'John Doe',
      }
    });
    """,
    given: [request: offline_request(playwright)] do
    APIRequestContext.post!(request, "https://example.com/api/createBook",
      data: %{title: "Book Title", author: "John Doe"}
    )
  end

  example "APIRequestContext.post",
    js: ~S"""
    await request.post('https://example.com/api/findBook', {
      form: {
        title: 'Book Title',
        author: 'John Doe',
      }
    });
    """,
    given: [request: offline_request(playwright)] do
    APIRequestContext.post!(request, "https://example.com/api/findBook",
      form: %{title: "Book Title", author: "John Doe"}
    )
  end

  example "APIRequestContext.post",
    js: ~S"""
    const form = new FormData();
    form.set('name', 'John');
    form.append('name', 'Doe');
    // Send two file fields with the same name.
    form.append('file', new File(['console.log(2024);'], 'f1.js', { type: 'text/javascript' }));
    form.append('file', new File(['hello'], 'f2.txt', { type: 'text/plain' }));
    await request.post('https://example.com/api/uploadForm', {
      multipart: form
    });
    """,
    given: [request: offline_request(playwright)] do
    form = [
      name: "John",
      name: "Doe",
      # Send two file fields with the same name.
      file: %{name: "f1.js", mimeType: "text/javascript", buffer: "console.log(2024);"},
      file: %{name: "f2.txt", mimeType: "text/plain", buffer: "hello"}
    ]

    APIRequestContext.post!(request, "https://example.com/api/uploadForm", multipart: form)
  end

  # APIRequestContext requests don't go through the browser's routes: the examples' requests to
  # https://example.com go through an HTTPS proxy of the test's own instead, which answers each
  # with the request it got (request line, headers and body) as text.
  defp offline_request(playwright) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    key = [key: {:namedCurve, :secp256r1}, digest: :sha256]
    chain = %{root: key, peer: key}
    %{server_config: tls} = :public_key.pkix_test_data(%{server_chain: chain, client_chain: chain})
    spawn_link(fn -> serve(listen, tls) end)

    Playwright.request(playwright)
    |> APIRequest.new_context!(proxy: %{server: "http://127.0.0.1:#{port}"}, ignore_https_errors: true)
  end

  # One connection at a time: the examples await each request.
  defp serve(listen, tls) do
    {:ok, tcp} = :gen_tcp.accept(listen)
    {"CONNECT " <> _, _} = recv(fn -> :gen_tcp.recv(tcp, 0) end, "")
    :ok = :gen_tcp.send(tcp, "HTTP/1.1 200 Connection Established\r\n\r\n")
    {:ok, socket} = :ssl.handshake(tcp, tls)
    {head, body} = recv(fn -> :ssl.recv(socket, 0) end, "")
    [_, length] = Regex.run(~r/^content-length: *(\d+)/mi, head) || [nil, "0"]
    body = recv_body(fn -> :ssl.recv(socket, 0) end, body, String.to_integer(length))
    echo = head <> "\r\n\r\n" <> body

    :ok =
      :ssl.send(
        socket,
        "HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nconnection: close\r\ncontent-length: #{byte_size(echo)}\r\n\r\n#{echo}"
      )

    :ssl.close(socket)
    serve(listen, tls)
  end

  # The head (up to the blank line) and the bytes after it.
  defp recv(recv, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, rest] -> {head, rest}
      [_] -> with {:ok, data} <- recv.(), do: recv(recv, acc <> data)
    end
  end

  defp recv_body(_recv, body, length) when byte_size(body) >= length, do: body
  defp recv_body(recv, body, length), do: with({:ok, data} <- recv.(), do: recv_body(recv, body <> data, length))
end
