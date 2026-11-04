Logger.configure(level: :info)

defmodule PlaywrightJS.TestHelper do
  alias PlaywrightJS.OutOfProcess
  alias PlaywrightJS.Client.{Browser, BrowserContext, BrowserType, Page, Playwright}

  @fixtures Path.expand("../../e2e/fixtures", __DIR__)

  def fixture_url(name), do: "file://" <> URI.encode(Path.join(@fixtures, name))
  def fixture_path(name), do: Path.join(@fixtures, name)

  @doc "Start driver + chromium; returns a map and registers cleanup."
  def launch do
    %{playwright: playwright, stop: stop} = OutOfProcess.start()
    browser = BrowserType.launch(Playwright.chromium(playwright))
    context = Browser.new_context(browser)
    page = BrowserContext.new_page(context)
    %{playwright: playwright, browser: browser, context: context, page: page, stop: stop}
  end

  def close(%{browser: browser, stop: stop}) do
    Browser.close(browser)
    stop.()
  end

  @doc "Minimal HTTP/1.1 server: `routes` maps a path to {content_type, body}. Returns base URL."
  def http_server(routes) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :http_bin, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    pid = spawn(fn -> accept_loop(listen, routes) end)
    :gen_tcp.controlling_process(listen, pid)
    "http://127.0.0.1:#{port}"
  end

  defp accept_loop(listen, routes) do
    {:ok, socket} = :gen_tcp.accept(listen)
    spawn(fn -> serve(socket, routes) end)
    accept_loop(listen, routes)
  end

  defp serve(socket, routes) do
    {:ok, {:http_request, _method, {:abs_path, path}, _}} = :gen_tcp.recv(socket, 0)
    skip_headers(socket)
    {type, body} = Map.get(routes, path |> String.split("?") |> hd(), {"text/plain", "not found"})
    status = if Map.has_key?(routes, path |> String.split("?") |> hd()), do: "200 OK", else: "404 Not Found"

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status}\r\ncontent-type: #{type}\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <> body
    )

    :gen_tcp.close(socket)
  end

  defp skip_headers(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, :http_eoh} -> :ok
      {:ok, _} -> skip_headers(socket)
      _ -> :ok
    end
  end

  def page_url(%{page: page}), do: Page.url(page)
end

ExUnit.start()
