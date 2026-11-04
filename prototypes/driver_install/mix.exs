defmodule DriverInstall.MixProject do
  use Mix.Project

  def project do
    [app: :driver_install, version: "0.1.0", elixir: "~> 1.18", deps: []]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]]
  end
end
