# upstream: playwright/_impl/_event_context_manager.py
defmodule Playwright.Impl.EventContextManagerImpl do
  defstruct [:_future]

  # upstream: _event_context_manager.py:22
  def init(future), do: %__MODULE__{_future: future}

  # upstream: _event_context_manager.py:26
  def future(self), do: self._future

  # upstream: _event_context_manager.py:29
  def aenter(self), do: self._future

  # upstream: _event_context_manager.py:32
  def aexit(self), do: Asyncio.Future.await(self._future)

  # upstream: sync_api/_sync_base.py EventInfo.value (sync flavour of `async with ... as info: ...; info.value`)
  def value(self), do: Asyncio.Future.await(self._future)
end
