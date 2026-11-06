defmodule PlaywrightEx.Runtime.Api do
  @moduledoc """
  Runtime support (not ported from upstream): the entry point of a public API call.

  Upstream derives `apiName` ("page.waitForEvent") from the JS stack in
  `captureLibraryStackTrace`. BEAM stack traces drop tail-call frames, so the public entry
  point records its name instead (`PlaywrightEx.Client.ClientStackTrace` reads it).
  The generated facade wraps every call in `call/3`.
  """
  alias PlaywrightEx.Runtime.Zones
  alias PlaywrightEx.TargetClosedError

  @doc "Runs `fun` as the public API call `api_name` (e.g. `\"browserType.launch\"`) on `receiver`."
  def call(api_name, _receiver, fun) do
    if !api_name or Zones.data(:apiName) do
      fun.()
    else
      try do
        Zones.with(:apiName, api_name, fun)
      rescue
        # A field read of a disposed object raises before `_wrapApiCall` (JS reads the stale value
        # and the server rejects the call): the error gets the API name all the same.
        e in TargetClosedError ->
          prefix = api_name <> ": "
          e = if String.starts_with?(e.message, prefix), do: e, else: %{e | message: prefix <> e.message}
          reraise e, __STACKTRACE__
      end
    end
  end
end
