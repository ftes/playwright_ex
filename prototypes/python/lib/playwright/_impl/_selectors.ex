# upstream: playwright/_impl/_selectors.py (subset)
defmodule Playwright.Impl.Selectors do
  use Py

  # upstream: _selectors.py:26
  def init(loop, dispatcher_fiber) do
    self = Py.new(__MODULE__)
    Py.set(self, :_loop, loop)
    Py.set(self, :_contexts_for_selectors, MapSet.new())
    Py.set(self, :_selector_engines, [])
    Py.set(self, :_dispatcher_fiber, dispatcher_fiber)
    Py.set(self, :_test_id_attribute_name, nil)
    self
  end
end
