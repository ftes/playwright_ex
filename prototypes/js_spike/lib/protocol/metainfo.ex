# Stand-in for the generated `getMetainfo` (packages/protocol/src/protocolMetainfo.ts):
# only the `internal` flag, extracted from packages/protocol/spec/*.yml (v1.64.1).
defmodule PlaywrightJS.Protocol.Metainfo do
  @internal %{
    "Android" => ~w(devices),
    "AndroidSocket" => ~w(write close),
    "AndroidDevice" => ~w(info close),
    "APIRequestContext" => ~w(fetchLog disposeAPIResponse dispose),
    "Artifact" => ~w(pathAfterFinished saveAs saveAsStream failure stream cancel delete),
    "Stream" => ~w(read close),
    "WritableStream" => ~w(write close),
    "Browser" => ~w(killForTests defaultUserAgentForTest newContextForReuse disconnectFromReusedContext),
    "BrowserContext" =>
      ~w(registerSelectorEngine setTestIdAttributeName showRecorder startRecording stopRecording exposeConsoleApi createTempFiles updateSubscription),
    "Disposable" => ~w(dispose),
    "ElectronApplication" => ~w(browserWindow updateSubscription),
    "Frame" => ~w(resolveSelector highlight hideHighlight),
    "JSHandle" => ~w(dispose),
    "LocalUtils" =>
      ~w(zip harOpen harLookup harClose harUnzip connect tracingStarted addStackToTracingNoReply traceDiscarded globToRegex asLocatorDescription),
    "Request" => ~w(response rawRequestHeaders),
    "Route" => ~w(redirectNavigationRequest),
    "WebSocketRoute" => ~w(ensureOpened closePage closeServer),
    "Response" => ~w(securityDetails serverAddr rawResponseHeaders httpVersion sizes),
    "Page" => ~w(resolveLocatorHandlerNoReply screencastFrameAck updateSubscription setDockTile),
    "Root" => ~w(initialize),
    "JsonPipe" => ~w(send close),
    "BindingCall" => ~w(reject resolve),
    "Debugger" => ~w(enable),
    "Tracing" => ~w(harStart harExport),
    "Worker" => ~w(updateSubscription)
  }

  def get(type, method), do: %{internal: to_string(method) in Map.get(@internal, type, [])}
end
