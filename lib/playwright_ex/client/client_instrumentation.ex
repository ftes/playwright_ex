defmodule PlaywrightEx.Client.ClientInstrumentation do
  @upstream "packages/playwright-core/src/client/clientInstrumentation.ts"
  @moduledoc """
  Port of `#{@upstream}`.

  The `Proxy` becomes one function per `ClientInstrumentation` method. A listener is a map from
  the JS method names to functions (`%{runBeforeCreateBrowserContext: fn options -> options end}`),
  each optional, as the JS interface's members.

  Deviations: JS listeners mutate the options of `runBeforeCreateBrowserContext` and
  `runBeforeCreateRequestContext`; here they return them, and the hook returns the options of the
  last listener. The `ApiCallData` the `onApiCall*` listeners get is a copy (the api zone): they
  cannot assign its `callId` or `userData`.

  The instrumentation is owned by the connection that creates it (`createInstrumentation` in
  `new Connection`); a remote connection shares its parent's (`connect.ts`).
  """
  import PlaywrightEx.Runtime.Heap

  defstruct [:guid, :conn, :table]

  # Elixir only: `owner` owns its rows (`PlaywrightEx.Runtime.Heap.new_object/2`).
  def create_instrumentation(owner \\ nil) do
    this = new_object(__MODULE__, owner)
    put(this, :listeners, [])
    this
  end

  def add_listener(this, listener), do: update(this, :listeners, &(&1 ++ [listener]))

  # `listeners.splice(listeners.indexOf(listener), 1)`: an unknown listener removes the last one.
  def remove_listener(this, listener) do
    update(this, :listeners, fn listeners ->
      List.delete_at(listeners, Enum.find_index(listeners, &(&1 == listener)) || -1)
    end)
  end

  def remove_all_listeners(this), do: put(this, :listeners, [])

  def on_api_call_begin(this, api_call, channel), do: _on(this, :onApiCallBegin, [api_call, channel])
  def on_api_call_end(this, api_call), do: _on(this, :onApiCallEnd, [api_call])
  def on_will_pause(this, options), do: _on(this, :onWillPause, [options])
  def on_page(this, page), do: _on(this, :onPage, [page])

  def run_before_create_browser_context(this, options), do: _run_options(this, :runBeforeCreateBrowserContext, options)
  def run_before_create_request_context(this, options), do: _run_options(this, :runBeforeCreateRequestContext, options)
  def run_after_create_browser_context(this, context), do: _on(this, :runAfterCreateBrowserContext, [context])
  def run_after_create_request_context(this, context), do: _on(this, :runAfterCreateRequestContext, [context])
  def run_before_close_browser_context(this, context), do: _on(this, :runBeforeCloseBrowserContext, [context])
  def run_before_close_request_context(this, context), do: _on(this, :runBeforeCloseRequestContext, [context])

  # `for (const listener of listeners) (listener as any)[prop]?.(...params);`
  defp _on(this, prop, params) do
    for listener <- get(this, :listeners), fun = listener[prop], do: apply(fun, params)
    nil
  end

  defp _run_options(this, prop, options) do
    Enum.reduce(get(this, :listeners), options, fn listener, options ->
      if fun = listener[prop], do: fun.(options), else: options
    end)
  end
end
