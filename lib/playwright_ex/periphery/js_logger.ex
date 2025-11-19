defmodule PlaywrightEx.JsLogger do
  @moduledoc """
  Behaviour for custom Javascript loggers.
  """
  @type level :: Logger.level()
  @type text :: binary()
  @type playwright_message :: %{params: map()}

  @callback log(level(), text(), playwright_message()) :: any()
end
