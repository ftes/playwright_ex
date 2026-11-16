# Copyright (c) Microsoft Corporation.
# Ported to Elixir and modified by the playwright_ex authors.
# SPDX-License-Identifier: Apache-2.0

defmodule Playwright.Client.WebSocketRouteHandler do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `WebSocketRouteHandler` in `#{@upstream}`: a plain struct, it has no mutable state.

  Deviations: the constructor takes the `LocalUtils` first, as string globs become regexes
  through the driver (`Playwright.Isomorphic.UrlMatch`). `_callers` is the registrant's
  `$callers`: the handler and a function `url` run on its behalf (`Playwright.Runtime.Callers`).
  """
  alias Playwright.Client.ClientHelper
  alias Playwright.Client.WebSocketRoute
  alias Playwright.Isomorphic.UrlMatch
  alias Playwright.Runtime.Callers
  alias Playwright.Runtime.Promise

  defstruct [:_localUtils, :_baseURL, :url, :handler, :_callers]

  def new(local_utils, base_url, url, handler) do
    # deviation: `_callers` (see the moduledoc).
    this = %__MODULE__{
      _localUtils: local_utils,
      _baseURL: base_url,
      url: url,
      handler: handler,
      _callers: Callers.capture()
    }

    # Eagerly validate string globs so that invalid patterns throw at the call site
    # (e.g. page.routeWebSocket()) rather than silently failing later.
    if is_binary(url), do: UrlMatch.resolve_glob_to_regex_pattern(local_utils, base_url, url, true)
    this
  end

  def prepare_interception_patterns(handlers) do
    {patterns, all} =
      Enum.reduce(handlers, {[], false}, fn handler, {patterns, all} ->
        serialized = UrlMatch.serialize_url_match(handler.url)
        if serialized, do: {patterns ++ [serialized], all}, else: {patterns, true}
      end)

    if all, do: [%{glob: "**/*"}], else: patterns
  end

  def matches(this, ws_url) do
    # deviation: a function `url` is a user callback too, run on the registrant's behalf
    # (`Runtime.Callers`). The LocalUtils comes first: globs become regexes through the driver (UrlMatch).
    Callers.run_as(this._callers, fn ->
      UrlMatch.url_matches(this._localUtils, this._baseURL, ws_url, this.url, true)
    end)
  end

  def handle(this, web_socket_route) do
    handler = this.handler
    # deviation: the `webSocketRoute` listener's process runs on the registrant's behalf from here.
    Callers.adopt(this._callers)
    result = ClientHelper.call_function(handler, [web_socket_route])
    # `await` adopts a returned promise
    if is_struct(result, Promise), do: Promise.await(result)
    WebSocketRoute._after_handle(web_socket_route)
  end
end
