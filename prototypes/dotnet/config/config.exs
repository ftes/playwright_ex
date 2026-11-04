import Config

config :playwright_dotnet_port, validate_protocol: config_env() == :test
