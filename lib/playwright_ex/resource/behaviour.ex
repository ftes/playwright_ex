defmodule PlaywrightEx.Resource.Behaviour do
  @moduledoc false

  @callback maybe_start(map(), map()) :: :ok
  @callback call_resource(pid(), term(), timeout()) :: any()
end
