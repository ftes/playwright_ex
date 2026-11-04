# Constructor-only stand-ins for upstream ChannelOwner classes that the scenario instantiates but does not use.
# Not counted toward equivalence.
for {module, upstream} <- [
      {Playwright.Impl.LocalUtils, "LocalUtils.java"},
      {Playwright.Impl.TracingImpl, "TracingImpl.java"},
      {Playwright.Impl.DebuggerImpl, "DebuggerImpl.java"},
      {Playwright.Impl.APIRequestContextImpl, "APIRequestContextImpl.java"},
      {Playwright.Impl.RequestImpl, "RequestImpl.java"},
      {Playwright.Impl.ResponseImpl, "ResponseImpl.java"},
      {Playwright.Impl.ElementHandleImpl, "ElementHandleImpl.java"},
      {Playwright.Impl.JSHandleImpl, "JSHandleImpl.java"},
      {Playwright.Impl.Stream, "Stream.java"},
      {Playwright.Impl.UnportedObject, "(unknown type)"}
    ] do
  defmodule module do
    @moduledoc "Stand-in for upstream #{upstream} (constructor only)."
    use Playwright.Impl.ChannelOwner
    def new(parent, type, guid, initializer), do: ChannelOwner.init(__MODULE__, parent, type, guid, initializer)
  end
end
