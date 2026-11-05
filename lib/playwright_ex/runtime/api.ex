defmodule PlaywrightEx.Runtime.Api do
  @moduledoc """
  Runtime support (not ported from upstream): the entry point of a public API call.

  Upstream derives `apiName` ("page.waitForEvent") from the JS stack in
  `captureLibraryStackTrace`. BEAM stack traces drop tail-call frames, so the public entry
  point records its name instead (`PlaywrightEx.Client.ClientStackTrace` reads it).
  The generated facade wraps every call in `call/3`.
  """
  alias PlaywrightEx.Runtime.Zones

  @doc "Runs `fun` as the public API call `api_name` (e.g. `\"browserType.launch\"`) on `receiver`."
  def call(api_name, _receiver, fun) do
    if !api_name or Zones.data(:apiName),
      do: fun.(),
      else: Zones.with(:apiName, api_name, fun)
  end
end
