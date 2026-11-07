defmodule PlaywrightEx.Library.BrowsercontextFetchAlgorithmsTest do
  @upstream "tests/library/browsercontext-fetch-algorithms.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.APIResponse
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.TestServer

  @moduletag :page

  # res.end(body): the body is sent with Content-Length.
  defp send_body(conn, body), do: Plug.Conn.send_resp(conn, 200, body)

  # res.removeHeader('Content-Length'); res.end(body) / res.write(body): Bandit omits Content-Length only when chunked.
  defp send_chunked(conn, body) do
    {:ok, conn} = conn |> Plug.Conn.send_chunked(200) |> Plug.Conn.chunk(body)
    conn
  end

  # describe('algorithms')
  @response_body "str"

  for {type, zipped} <- [
        gzip: :zlib.gzip(@response_body),
        deflate: :zlib.compress(@response_body),
        # zlib.brotliCompress('str'), from Node: OTP has no brotli.
        br: Base.decode64!("CwGAc3RyAw==")
      ] do
    describe "algorithms #{type} decompression" do
      @describetag type: to_string(type), zipped: zipped

      test "FE-180 should support decompression", %{context: context, server: server, type: type, zipped: zipped} do
        TestServer.set_route(server, "/compressed", fn conn ->
          conn |> Plug.Conn.put_resp_header("content-encoding", type) |> send_body(zipped)
        end)

        response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
        assert APIResponse.text!(response) == @response_body
      end

      test "FE-181 should not fail if response content-length header is missing (#{type})",
           %{context: context, server: server, type: type, zipped: zipped} do
        TestServer.set_route(server, "/compressed", fn conn ->
          conn |> Plug.Conn.put_resp_header("content-encoding", type) |> send_chunked(zipped)
        end)

        response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
        assert APIResponse.text!(response) == @response_body
      end

      test "FE-182 should not fail with chunked responses (without Content-Length header)",
           %{context: context, server: server, type: type, zipped: zipped} do
        TestServer.set_route(server, "/compressed", fn conn ->
          conn |> Plug.Conn.put_resp_header("content-encoding", type) |> send_chunked(zipped)
        end)

        response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
        assert APIResponse.text!(response) == @response_body
      end

      test "FE-183 should not fail with an empty response without content-length header (Z_BUF_ERROR)",
           %{context: context, server: server, type: type} do
        TestServer.set_route(server, "/compressed", fn conn ->
          conn |> Plug.Conn.put_resp_header("content-encoding", type) |> send_chunked("")
        end)

        response = APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
        assert APIResponse.text!(response) == ""
      end

      test "FE-184 should not fail with an empty response with content-length header (Z_BUF_ERROR)",
           %{context: context, server: server, type: type} do
        TestServer.set_route(server, "/compressed", fn conn ->
          conn |> Plug.Conn.put_resp_header("content-encoding", type) |> send_body("")
        end)

        APIRequestContext.get!(BrowserContext.request(context), server.prefix <> "/compressed")
      end
    end
  end
end
