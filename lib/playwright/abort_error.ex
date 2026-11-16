# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.AbortError do
  @moduledoc """
  A call was cancelled through its `signal:` (`Playwright.AbortController`).

  The fields are those of `Playwright.PlaywrightError`; `name` is `"AbortError"` and `cause` the
  reason given to `Playwright.AbortController.abort/2`. Port of JS `AbortError`
  (`packages/playwright-core/src/client/errors.ts`).
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

  defexception message: "The operation was aborted",
               name: "AbortError",
               log: [],
               details: nil,
               stack: "",
               code: nil,
               cause: nil
end
