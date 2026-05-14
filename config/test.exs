import Config

config :playwright_ex,
  executable: "assets/node_modules/playwright/cli.js",
  timeout: String.to_integer(System.get_env("PW_TIMEOUT", "10000")),
  fail_on_unknown_opts: true
