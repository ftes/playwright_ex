defmodule PlaywrightEx.Client.HarRouter do
  @upstream "packages/playwright-core/src/client/harRouter.ts"
  @moduledoc "Port of `#{@upstream}`: a plain struct, it has no mutable state."
  alias PlaywrightEx.Client.BrowserContext
  alias PlaywrightEx.Client.LocalUtils
  alias PlaywrightEx.Client.Page
  alias PlaywrightEx.Client.Request
  alias PlaywrightEx.Client.Route
  alias PlaywrightEx.Runtime.Promise

  require Logger

  defstruct [:_localUtils, :_harId, :_notFoundAction, :_options]

  def create(local_utils, file, not_found_action, options) do
    result = LocalUtils.har_open(local_utils, %{file: file})
    if result[:error], do: raise(result.error)
    new(local_utils, result.harId, not_found_action, options)
  end

  defp new(local_utils, har_id, not_found_action, options) do
    %__MODULE__{_localUtils: local_utils, _harId: har_id, _options: options, _notFoundAction: not_found_action}
  end

  defp _handle(this, route) do
    request = Route.request(route)

    response =
      LocalUtils.har_lookup(this._localUtils, %{
        harId: this._harId,
        url: Request.url(request),
        method: Request.method(request),
        headers: Request.headers_array(request),
        postData: Request.post_data_buffer(request) || nil,
        isNavigationRequest: Request.is_navigation_request(request)
      })

    cond do
      response.action == "redirect" ->
        # debugLogger.log('api', ...)
        Logger.debug("pw:api HAR: #{Request.url(Route.request(route))} redirected to #{response.redirectURL}")
        Route._redirect_navigation_request(route, response.redirectURL)

      response.action == "fulfill" ->
        # If the response status is -1, the request was canceled or stalled, so we just stall it here.
        # See https://github.com/microsoft/playwright/issues/29311.
        # Upstream to-do: it'd be better to abort such requests, but then we likely need to respect the timing,
        # because the request might have been stalled for a long time until the very end of the
        # test when HAR was recorded but we'd abort it immediately.
        if response.status != -1 do
          # route.fulfill does not support multiple set-cookie headers. We need to merge them into one.
          transformed_headers =
            Enum.reduce(response.headers, %{}, fn %{name: name, value: value}, headers_map ->
              cond do
                # non-set-cookie header gets set as-is
                String.downcase(name) != "set-cookie" -> Map.put(headers_map, name, value)
                # first set-cookie header gets included as-is
                !headers_map["set-cookie"] -> Map.put(headers_map, "set-cookie", value)
                # subsequent set-cookie headers get appended to existing header
                true -> Map.update!(headers_map, "set-cookie", &(&1 <> "\n" <> value))
              end
            end)

          Route.fulfill(route, %{
            status: response.status,
            headers: transformed_headers,
            body: response[:body] && {:binary, response.body}
          })
        end

      true ->
        # debugLogger.log('api', ...)
        if response.action == "error", do: Logger.debug("pw:api HAR: " <> response.message)
        # Report the error, but fall through to the default handler.

        if this._notFoundAction == "abort",
          do: Route.abort(route),
          else: Route.fallback(route)
    end

    nil
  end

  def add_context_route(this, context) do
    BrowserContext.route(context, this._options[:urlMatch] || "**/*", fn route -> _handle(this, route) end)
  end

  def add_page_route(this, page) do
    Page.route(page, this._options[:urlMatch] || "**/*", fn route -> _handle(this, route) end)
  end

  # [Symbol.asyncDispose]  -- not ported: await using

  def dispose(this) do
    Promise.void(fn -> LocalUtils.har_close(this._localUtils, %{harId: this._harId}) end)

    nil
  end
end
