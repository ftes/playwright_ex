import Config

config :playwright_ex, fail_on_unknown_opts: false

import_config "#{config_env()}.exs"
