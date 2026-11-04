defmodule Playwright.Core.Selectors do
  @moduledoc "upstream: Core/Selectors.cs (fields only; RegisterAsync/SetTestIdAttribute not ported)"
  defstruct selector_engines: [], test_id_attribute_name: nil

  def new, do: %__MODULE__{}
end
