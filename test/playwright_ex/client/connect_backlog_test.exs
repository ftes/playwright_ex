defmodule PlaywrightEx.Client.ConnectBacklogTest do
  # OTP_BACKLOG: `connect` stores the browser before the next message (a close right after the
  # `initialize` reply still disconnects it), and a closed remote connection stops its processes.
  @upstream nil
  use PlaywrightEx.UpstreamCase, async: false

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Runtime.Facade

  @moduletag timeout: 300_000

  # A TCP proxy to `endpoint`. With `cut: true` it holds the server's `initialize` reply until the
  # process registered as `:connect_backlog_watcher` says go, then forwards it and closes the
  # client's socket (the driver then reports the pipe closed).
  defp proxy(endpoint, cut) do
    %URI{host: host, port: port} = uri = URI.parse(endpoint)
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, proxy_port} = :inet.port(listen)
    pid = spawn_link(fn -> accept(listen, ip, port, cut) end)
    :ok = :gen_tcp.controlling_process(listen, pid)
    URI.to_string(%{uri | host: "127.0.0.1", port: proxy_port})
  end

  defp accept(listen, ip, port, cut) do
    {:ok, client} = :gen_tcp.accept(listen)
    {:ok, server} = :gen_tcp.connect(ip, port, [:binary, active: false])
    spawn(fn -> pump(client, server, nil) end)
    downstream = spawn(fn -> pump(server, client, if(cut, do: "")) end)
    :ok = :gen_tcp.controlling_process(server, downstream)
    accept(listen, ip, port, cut)
  end

  # `tail`: nil (forward only) or the end of what passed so far (to find the reply across chunks).
  defp pump(from, to, tail) do
    case :gen_tcp.recv(from, 0) do
      {:ok, data} ->
        seen = if tail, do: tail <> data

        if seen && String.contains?(seen, ~s("result":{"playwright")) do
          send(:connect_backlog_watcher, {:hold, self()})
          receive do: (:go -> :ok)
          :gen_tcp.send(to, data)
          :gen_tcp.close(to)
          :gen_tcp.close(from)
        else
          :gen_tcp.send(to, data)
          pump(from, to, seen && binary_part(seen, max(0, byte_size(seen) - 64), min(64, byte_size(seen))))
        end

      {:error, _} ->
        :gen_tcp.close(to)
    end
  end

  # The connection processes linked to the local one (a remote connection's `Conn`).
  defp conns(%{conn: parent}) do
    {:links, links} = Process.info(parent, :links)
    for pid <- links, is_pid(pid), match?({PlaywrightEx.Runtime.Conn, :init, _}, :proc_lib.initial_call(pid)), do: pid
  end

  # Suspends the remote connection while its `initialize` reply and the transport's close reach it,
  # so both are in its mailbox, in that order, when it resumes. The connecting process (`task`)
  # stays suspended until the close has been dispatched: JS dispatches nothing between the reply
  # and the statements after `await connection.initializePlaywright()`.
  defp watcher do
    receive do
      {:child, child, task} ->
        receive do
          {:hold, pump} ->
            :sys.suspend(child)
            send(pump, :go)
            wait_close_queued(child, 400)
            :erlang.suspend_process(task)
            :sys.resume(child)
            Process.sleep(200)
            :erlang.resume_process(task)
        end
    end
  end

  defp wait_close_queued(child, attempts) do
    {:messages, messages} = Process.info(child, :messages)

    if attempts > 0 and not Enum.any?(messages, &match?({:"$gen_call", _, {:run, _, _}}, &1)) do
      Process.sleep(5)
      wait_close_queued(child, attempts - 1)
    end
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end

  test "a close right after initialize disconnects the browser", %{
    browser_type: browser_type,
    start_remote_server: start_remote_server
  } do
    server = start_remote_server.("launchServer", %{})
    endpoint = proxy(PlaywrightEx.RemoteServer.ws_endpoint(server), true)

    # The first iteration whose browser stays connected.
    failed =
      Enum.find(1..100, fn _ ->
        watcher = spawn(&watcher/0)
        Process.register(watcher, :connect_backlog_watcher)
        known = conns(browser_type)
        hook = fn -> send(watcher, {:child, hd(conns(browser_type) -- known), self()}) end

        # A test hook is no API option: the client is called directly.
        {:ok, browser} =
          Facade.async("browserType.connect", browser_type, fn ->
            PlaywrightEx.Client.BrowserType.connect(browser_type, endpoint, %{__testHookBeforeCreateBrowser: hook})
          end)

        connected = !eventually(fn -> !Browser.is_connected(browser) end)
        Process.exit(watcher, :kill)
        connected
      end)

    assert failed == nil, "iteration #{failed}: the browser stayed connected"
  end

  defp counts(%{conn: parent} = browser_type) do
    {:links, links} = Process.info(parent, :links)
    tables = Enum.count(:ets.all(), &(:ets.info(&1, :name) == :playwright_ex_conn))
    %{links: length(links), conns: length(conns(browser_type)), tables: tables}
  end

  test "a closed remote connection stops its processes", %{
    browser_type: browser_type,
    start_remote_server: start_remote_server
  } do
    server = start_remote_server.("launchServer", %{})
    endpoint = PlaywrightEx.RemoteServer.ws_endpoint(server)
    connect_close = fn -> Browser.close!(BrowserType.connect!(browser_type, endpoint)) end
    # Warm up (the first connect creates objects of the local connection).
    Task.await(Task.async(connect_close))
    assert eventually(fn -> conns(browser_type) == [] end)
    before = counts(browser_type)
    rows = :ets.info(browser_type.table, :size)

    for _ <- 1..20, do: Task.await(Task.async(connect_close))

    # No more than before (the warm-up's forwarder may still have been exiting then).
    no_growth = fn -> Enum.all?(counts(browser_type), fn {key, count} -> count <= before[key] end) end
    assert eventually(no_growth), "#{inspect(before)} -> #{inspect(counts(browser_type))}"

    # The forwarders free their rows as they exit, so this settles after the processes do. The
    # leak was ~117 rows per cycle; then a JsonPipe disposed after its connection stopped kept 6
    # (Linux firefox: ~30 rows after 20 cycles).
    assert eventually(fn -> :ets.info(browser_type.table, :size) - rows < 10 end),
           "#{:ets.info(browser_type.table, :size) - rows} new rows"
  end
end
