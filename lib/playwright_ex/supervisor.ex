defmodule PlaywrightEx.Supervisor do
  @moduledoc """
  The OTP form of `outofprocess.start()`: one driver with its baton.

      children = [{PlaywrightEx.Supervisor, name: MyApp.Playwright}]
      playwright = PlaywrightEx.playwright(MyApp.Playwright)

  Options:

    * `:name` - defaults to `PlaywrightEx`.
    * `:executable`, `:node`, `:cache_dir` - see `PlaywrightEx.Driver`.
    * `:env` - extra environment variables for the driver process.

  Children (`:rest_for_one`): the baton (`PlaywrightEx.Runtime.Baton`), then the driver
  connection (`PlaywrightEx.OutOfProcess`), so a driver restart keeps the baton.
  """
  use Supervisor

  alias PlaywrightEx.OutOfProcess
  alias PlaywrightEx.Runtime.Baton

  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:executable, :node, :cache_dir, name: PlaywrightEx, env: []])
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc false
  def out_of_process(name), do: Module.concat(name, OutOfProcess)

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    baton = Module.concat(name, Baton)

    children = [
      {Baton, name: baton},
      {OutOfProcess, Keyword.merge(opts, name: out_of_process(name), baton: baton)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
