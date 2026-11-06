defmodule PlaywrightEx.Supervisor do
  @moduledoc """
  The OTP form of `outofprocess.start()`: one driver with its connection.

      children = [{PlaywrightEx.Supervisor, name: MyApp.Playwright}]
      playwright = PlaywrightEx.playwright(MyApp.Playwright)

  Options:

    * `:name` - defaults to `PlaywrightEx`.
    * `:executable`, `:node`, `:cache_dir` - see `PlaywrightEx.Driver`.
    * `:env` - extra environment variables for the driver process.

  Child: the driver connection (the driver's pipe and the connection process). The child id is
  the `:name`, so drivers of different names can share a supervision tree.

  ## Lifetimes

  When the driver exits, its connection is closed and the supervisor starts a new driver, with a
  new root object: calls on handles of the old one fail with `PlaywrightEx.TargetClosedError`, so
  get the root again with `PlaywrightEx.playwright/1`. Browsers and contexts are not closed when
  the process that created them exits; only the data the library keeps for closed ones is freed
  then. So close what you open, as tests close their contexts in `on_exit`. Starting installs the
  driver first if it is missing (`PlaywrightEx.Driver.ensure_installed/1`): a download that
  blocks `start_link/1`.
  """
  use Supervisor

  alias PlaywrightEx.OutOfProcess

  @typedoc "An option of `start_link/1`, see the module docs."
  @type option ::
          {:name, atom()}
          | {:executable, Path.t()}
          | {:node, Path.t()}
          | {:cache_dir, Path.t()}
          | {:env, Enumerable.t({String.t(), String.t()})}

  @doc """
  Starts the driver and its connection under a supervisor registered as `:name`. Returns once
  the root object is ready (`PlaywrightEx.playwright/1`), after installing the driver if needed.
  """
  @spec start_link([option()]) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, [:executable, :node, :cache_dir, name: PlaywrightEx, env: []])
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc "A child spec whose id is the `:name` (`PlaywrightEx` by default)."
  @spec child_spec([option()]) :: Supervisor.child_spec()
  def child_spec(opts), do: opts |> super() |> Map.put(:id, Keyword.get(opts, :name, PlaywrightEx))

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
    children = [{OutOfProcess, Keyword.merge(opts, name: out_of_process(name))}]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
