# upstream: packages/playwright-core/src/outofprocess.ts
defmodule PlaywrightJS.OutOfProcess do
  import PlaywrightJS.Runtime.Heap
  alias PlaywrightJS.Runtime.{Baton, Promise, PortTransport}
  alias PlaywrightJS.Client.Connection

  # upstream: outofprocess.ts:29
  def start(env \\ %{}) do
    client = __MODULE__.PlaywrightClient.new(env)
    playwright = Promise.await(get(client, :_playwright))
    put(playwright, :driverProcess, get(client, :_driverProcess))
    %{playwright: playwright, stop: fn -> __MODULE__.PlaywrightClient.stop(client) end}
  end

  # upstream: outofprocess.ts:36
  defmodule PlaywrightClient do
    import PlaywrightJS.Runtime.Heap
    defstruct [:guid, :conn]

    @default_cli Path.expand("../../node_modules/playwright/cli.js", __DIR__)

    # upstream: outofprocess.ts:41
    def new(env) do
      # The JS thread is implicit; here it is a token (baton) every object belongs to.
      {:ok, pid} = Baton.start_link()
      loop = Baton.get(pid)
      this = new_object(loop, __MODULE__)
      put(this, :_closePromise, Promise.new(loop))
      connection = Connection.new(loop)

      put(
        this,
        :_driverProcess,
        Baton.with_baton(loop, fn ->
          {:ok, transport} =
            PortTransport.start_link(
              cli: System.get_env("PLAYWRIGHT_CLI", @default_cli),
              env: env,
              # transport.onmessage = message => connection.dispatch(JSON.parse(message));
              on_message: fn message -> Baton.post(loop, fn -> Connection.dispatch(connection, message) end) end,
              # transport.onclose = () => this._closePromise.resolve();
              on_close: fn -> Promise.resolve(get(this, :_closePromise), nil) end
            )

          transport
        end)
      )

      # connection.onmessage = message => transport.send(JSON.stringify(message));
      put(connection, :onmessage, fn message -> PortTransport.send_message(get(this, :_driverProcess), message) end)

      put(this, :_playwright, Promise.async(loop, fn -> Connection.initialize_playwright(connection) end))
      this
    end

    # upstream: outofprocess.ts:64
    def stop(this) do
      PortTransport.close(get(this, :_driverProcess))
      Promise.await(get(this, :_closePromise))
    end
  end
end
