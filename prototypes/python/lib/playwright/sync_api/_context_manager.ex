# upstream: playwright/sync_api/_context_manager.py
defmodule Playwright.SyncApi.PlaywrightContextManager do
  use Py
  alias Playwright.Impl.{Connection, ObjectFactory}
  alias Playwright.Impl.Transport.PipeTransport

  # upstream: _context_manager.py:31
  def init do
    self = Py.new(__MODULE__)
    Py.set(self, :_playwright, nil)
    Py.set(self, :_exit_was_called, false)
    self
  end

  # upstream: _context_manager.py:38
  def __enter__(self) do
    # (event loop / greenlet dispatcher fiber setup: the PipeTransport process is the loop)
    Py.set(
      self,
      :_connection,
      Connection.init(nil, &ObjectFactory.create_remote_object/4, PipeTransport.init(nil), nil)
    )

    Connection.run_as_sync(self[:_connection])

    try do
      Py.set(self, :_playwright, Asyncio.Future.await(self[:_connection][:playwright_future]))
    rescue
      e ->
        __exit__(self)
        reraise e, __STACKTRACE__
    end

    Py.set(self[:_playwright], :stop, fn -> __exit__(self) end)
    self[:_playwright]
  end

  # upstream: _context_manager.py:93
  def start(self), do: __enter__(self)

  # upstream: _context_manager.py:96
  def __exit__(self) do
    if not self[:_exit_was_called] do
      Py.set(self, :_exit_was_called, true)
      Connection.stop_sync(self[:_connection])
    end
  end
end
