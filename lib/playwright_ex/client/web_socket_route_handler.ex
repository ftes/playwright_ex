defmodule PlaywrightEx.Client.WebSocketRouteHandler do
  @upstream "packages/playwright-core/src/client/network.ts"
  @moduledoc """
  Port of `WebSocketRouteHandler` in `#{@upstream}`: a plain struct, it has no mutable state.

  Deviation: the constructor takes the `LocalUtils` first, as string globs become regexes
  through the driver (`PlaywrightEx.Isomorphic.UrlMatch`).
  """
  alias PlaywrightEx.Client.WebSocketRoute
  alias PlaywrightEx.Isomorphic.UrlMatch

  defstruct [:_localUtils, :_baseURL, :url, :handler]

  def new(local_utils, base_url, url, handler) do
    this = %__MODULE__{_localUtils: local_utils, _baseURL: base_url, url: url, handler: handler}
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
    UrlMatch.url_matches(this._localUtils, this._baseURL, ws_url, this.url, true)
  end

  def handle(this, web_socket_route) do
    handler = this.handler
    handler.(web_socket_route)
    WebSocketRoute._after_handle(web_socket_route)
  end
end
