defmodule PlaywrightEx.DriverTest do
  use ExUnit.Case, async: false
  alias PlaywrightEx.Driver

  setup do
    cache = Path.join(System.tmp_dir!(), "pwex-test-#{System.unique_integer([:positive])}")
    on_exit(fn -> if System.get_env("KEEP_CACHE") != "1", do: File.rm_rf!(cache) end)
    %{cache: cache}
  end

  test "no node on PATH: install, run-driver, initialize, launch chromium, close", %{cache: cache} do
    IO.puts("System.find_executable(\"node\") = #{inspect(System.find_executable("node"))}")
    IO.puts("PATH=#{System.get_env("PATH")}")
    assert System.find_executable("node") == nil

    {us, {node, [cli]}} = :timer.tc(fn -> Driver.ensure_installed(cache_dir: cache) end)
    IO.puts("driver install: #{div(us, 1000)} ms into #{Driver.install_dir(cache_dir: cache)}")
    assert node == Path.join(Driver.install_dir(cache_dir: cache), "node")

    # idempotent: second call does nothing
    {us2, _} = :timer.tc(fn -> Driver.ensure_installed(cache_dir: cache) end)
    assert us2 < 50_000

    assert File.ls!(Path.join(cache, Driver.driver_version())) == [
             Driver.install_dir(cache_dir: cache) |> Path.basename()
           ]

    {us3, :ok} =
      :timer.tc(fn -> Driver.install_browsers(["chromium", "--only-shell"], cache_dir: cache) end)

    IO.puts("install_browsers: #{div(us3, 1000)} ms")

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        args: [cli, "run-driver"],
        env: Enum.map(Driver.driver_env(), fn {k, v} -> {~c"#{k}", ~c"#{v}"} end)
      ])

    send_msg(port, %{
      id: 1,
      guid: "",
      method: "initialize",
      params: %{sdkLanguage: "python"},
      metadata: %{}
    })

    {result, creates} = await(port, 1, "", %{})
    playwright_guid = result["playwright"]["guid"]
    playwright = Map.fetch!(creates, playwright_guid)
    assert playwright["type"] == "Playwright"

    IO.puts(
      "root Playwright object: #{playwright_guid}, initializer keys: #{inspect(Map.keys(playwright["initializer"]))}"
    )

    chromium = playwright["initializer"]["chromium"]["guid"]

    send_msg(port, %{
      id: 2,
      guid: chromium,
      method: "launch",
      params: %{headless: true, timeout: 30_000},
      metadata: %{}
    })

    {%{"browser" => %{"guid" => browser}}, creates} = await(port, 2, "", creates)
    IO.puts("launched #{browser} version #{creates[browser]["initializer"]["version"]}")

    send_msg(port, %{id: 3, guid: browser, method: "close", params: %{}, metadata: %{}})
    {_, _} = await(port, 3, "", creates)
    IO.puts("browser closed")
    Port.close(port)
  end

  test "tampered download: clear error, nothing installed", %{cache: cache} do
    bad =
      put_in(
        Driver.checksums().playwright_core,
        "sha512-" <> Base.encode64(:binary.copy(<<0>>, 64))
      )

    error =
      assert_raise Driver.ChecksumError, fn ->
        Driver.install(cache_dir: cache, checksums: bad)
      end

    IO.puts("\n" <> error.message)
    assert error.message =~ "checksum mismatch for playwright-core.tgz"
    # temp dir cleaned up, target never created
    assert File.ls!(Path.join(cache, Driver.driver_version())) == []
    refute Driver.installed?(cache_dir: cache)

    # Node archive tampering (sha256 path), verified directly on a modified file.
    file = Path.join(cache, "node.tar.gz")
    File.write!(file, "not really node")

    assert_raise Driver.ChecksumError, ~r/sha256/, fn ->
      Driver.verify!(file, "sha256-hex:" <> Driver.checksums().node["darwin-arm64"])
    end
  end

  test "overrides and unsupported platforms" do
    assert {"/opt/pw/playwright", []} = Driver.executable(executable: "/opt/pw/playwright")

    assert {"/usr/local/bin/node", [cli]} =
             Driver.executable(node: "/usr/local/bin/node", cache_dir: "/c")

    assert String.ends_with?(cli, "/package/cli.js")
    assert {:ok, _} = Driver.platform()

    assert_raise RuntimeError, ~r/Supported: darwin-arm64/, fn ->
      Driver.install(
        platform: "freebsd-x64",
        checksums: %{Driver.checksums() | node: %{}},
        cache_dir: "/tmp/pwex-x"
      )
    end

    File.rm_rf!("/tmp/pwex-x")
  end

  defp send_msg(port, msg) do
    json = JSON.encode!(msg)
    Port.command(port, <<byte_size(json)::little-32, json::binary>>)
  end

  defp await(port, id, buffer, creates) do
    receive do
      {^port, {:data, data}} ->
        {buffer, frames} = frames(buffer <> data, [])

        Enum.reduce_while(frames, {:cont, creates}, fn frame, {:cont, acc} ->
          case JSON.decode!(frame) do
            %{"method" => "__create__", "params" => p} ->
              {:cont, {:cont, Map.put(acc, p["guid"], p)}}

            %{"id" => ^id, "error" => e} ->
              flunk("protocol error: #{inspect(e)}")

            %{"id" => ^id} = m ->
              {:halt, {:done, m["result"], acc}}

            _ ->
              {:cont, {:cont, acc}}
          end
        end)
        |> case do
          {:done, result, acc} -> {result, acc}
          {:cont, acc} -> await(port, id, buffer, acc)
        end

      {^port, {:exit_status, s}} ->
        flunk("driver exited with #{s}")
    after
      60_000 -> flunk("timeout waiting for response #{id}")
    end
  end

  defp frames(<<len::little-32, rest::binary>> = buf, acc) do
    case rest do
      <<frame::binary-size(^len), tail::binary>> -> frames(tail, [frame | acc])
      _ -> {buf, Enum.reverse(acc)}
    end
  end

  defp frames(buf, acc), do: {buf, Enum.reverse(acc)}
end
