# upstream: playwright/_impl/_playwright.py
defmodule Playwright.Impl.Playwright do
  use Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.Connection.ChannelOwner
  alias Playwright.Impl.{Connection, Selectors}
  import Connection, only: [from_channel: 1]

  # upstream: _playwright.py:31
  def init(parent, type, guid, initializer) do
    self = ChannelOwner.init(Py.new(__MODULE__), parent, type, guid, initializer)
    # self.request = APIRequest(self)  (omitted)
    Py.set(self, :chromium, from_channel(initializer["chromium"]))
    Py.set(self[:chromium], :_playwright, self)
    Py.set(self, :firefox, from_channel(initializer["firefox"]))
    Py.set(self[:firefox], :_playwright, self)
    Py.set(self, :webkit, from_channel(initializer["webkit"]))
    Py.set(self[:webkit], :_playwright, self)

    Py.set(self, :selectors, Selectors.init(self[:_loop], self[:_dispatcher_fiber]))

    Py.set(self, :devices, Connection.local_utils(self[:_connection])[:devices])
    self
  end

  # upstream: _playwright.py:47  (__getitem__)
  def fetch(self, value) when value in ["chromium", "firefox", "webkit"],
    do: {:ok, Py.get(self, String.to_existing_atom(value))}

  def fetch(self, attr) when is_atom(attr), do: {:ok, Py.get(self, attr)}

  # upstream: _playwright.py:56
  def _set_selectors(self, selectors), do: Py.set(self, :selectors, selectors)

  # upstream: _playwright.py:59
  def stop(_self), do: nil
end
