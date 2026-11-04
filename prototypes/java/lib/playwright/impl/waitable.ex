defmodule Playwright.Impl.Waitable do
  # upstream: Waitable.java:21
  # Java interface -> behaviour + dispatch on the struct's module.
  @callback is_done(struct()) :: boolean()
  @callback get(struct()) :: any()
  @callback dispose(struct()) :: any()

  def is_done(%module{} = waitable), do: module.is_done(waitable)
  def get(%module{} = waitable), do: module.get(waitable)
  def dispose(%module{} = waitable), do: module.dispose(waitable)
end
