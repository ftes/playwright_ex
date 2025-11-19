import Config

config :logger, level: :warning

config :playwright_ex, timeout: String.to_integer(System.get_env("PW_TIMEOUT", "500"))
