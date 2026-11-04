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
    name = Keyword.fetch!(opts, :name)
    event_loop = Module.concat(name, EventLoop)

    children = [
      {EventLoop, name: event_loop},
      {OutOfProcess, Keyword.merge(opts, name: out_of_process(name), event_loop: event_loop)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
