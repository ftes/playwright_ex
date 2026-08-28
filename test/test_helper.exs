ExUnit.start()

env =
  :playwright_ex
  |> Application.get_all_env()
  |> Keyword.put_new(:executable, "assets/node_modules/playwright/cli.js")

{:ok, _} = PlaywrightEx.Supervisor.start_link(env)
