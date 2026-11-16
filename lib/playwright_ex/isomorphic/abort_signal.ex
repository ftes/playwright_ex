# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule PlaywrightEx.Isomorphic.AbortSignal do
  @upstream "packages/isomorphic/abortSignal.ts"
  @moduledoc "Port of `#{@upstream}`. `null`/`undefined` is `nil` (and `:null`), `String(reason)` is `to_string/1` or `inspect/1`."

  def assertion_aborted_message(reason) do
    detail =
      cond do
        is_exception(reason) -> Exception.message(reason)
        reason in [nil, :null] -> ""
        String.Chars.impl_for(reason) -> to_string(reason)
        true -> inspect(reason)
      end

    "The assertion was aborted" <> if(detail != "", do: ": #{detail}", else: "")
  end
end
