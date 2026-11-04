defmodule Playwright.Impl.SelectorsImpl do
  # upstream: SelectorsImpl.java:32 (fields only; register/setTestIdAttribute not ported)
  defstruct [:id, test_id_attribute_name: "data-testid"]

  def new do
    this = %__MODULE__{id: make_ref()}
    Playwright.Impl.Heap.put(this, :contexts_for_selectors, [])
    Playwright.Impl.Heap.put(this, :selector_engines, [])
    this
  end
end
