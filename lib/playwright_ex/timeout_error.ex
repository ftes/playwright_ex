# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule PlaywrightEx.TimeoutError do
  @moduledoc """
  A call ran out of time.

  The fields are those of `PlaywrightEx.PlaywrightError`; `name` is `"TimeoutError"`. Port of JS
  `TimeoutError` (`packages/playwright-core/src/client/errors.ts`).
  """
  @typedoc "See the module docs for the fields."
  @type t :: %__MODULE__{
          message: String.t(),
          name: String.t(),
          log: [String.t()],
          details: map() | nil,
          stack: String.t(),
          code: String.t() | nil,
          cause: term()
        }

  defexception message: "", name: "TimeoutError", log: [], details: nil, stack: "", code: nil, cause: nil
end
