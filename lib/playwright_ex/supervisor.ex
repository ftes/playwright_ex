defmodule PlaywrightEx.Supervisor do
  @moduledoc """
  The OTP form of `outofprocess.start()`: one driver with its event loop.

      children = [{PlaywrightEx.Supervisor, name: MyApp.Playwright}]
      playwright = PlaywrightEx.playwright(MyApp.Playwright)

  Options:

    * `:name` - defaults to `PlaywrightEx`.
    * `:executable`, `:node`, `:cache_dir` - see `PlaywrightEx.Driver`.
    * `:env` - extra environment variables for the driver process.

  Children (`:rest_for_one`): the event loop (`PlaywrightEx.Runtime.EventLoop`), then the driver
  connection (`PlaywrightEx.OutOfProcess`), so a driver restart keeps the loop.
  """
  use Supervisor

  alias PlaywrightEx.OutOfProcess
  alias PlaywrightEx.Runtime.EventLoop

  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:executable, :node, :cache_dir, name: PlaywrightEx, env: []])
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc false
  def out_of_process(name), do: Module.concat(name, OutOfProcess)

  @impl true
  def init(opts) do
    # The client is loaded up front, as `require('playwright')` does: in interactive mode (dev,
    # test) modules load on first use, and that delay between two calls of one synchronous JS
    # section (`evaluate` sent, then the `console` subscription of `wait_for_event`) can let an
    # event the second one waits for pass unseen.
    :code.ensure_modules_loaded(Application.spec(:playwright_ex, :modules) || [])
    name = Keyword.fetch!(opts, :name)
    event_loop = Module.concat(name, EventLoop)

    children = [
      {EventLoop, name: event_loop},
      {OutOfProcess, Keyword.merge(opts, name: out_of_process(name), event_loop: event_loop)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
