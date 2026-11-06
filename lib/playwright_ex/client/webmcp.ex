defmodule PlaywrightEx.Client.WebMCP do
  @upstream "packages/playwright-core/src/client/webmcp.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."
  import PlaywrightEx.Client.ChannelOwner, only: [channel_call: 4]

  alias PlaywrightEx.Client.Frame
  alias PlaywrightEx.Client.JSHandle

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.WebMCP{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_frame]

  def new(frame) do
    %PlaywrightEx.WebMCP{_frame: frame}
  end

  def tools(this, options \\ %{}) do
    %{tools: tools} = channel_call(this._frame, :webmcpTools, %{}, Frame._timeout(this._frame, options))
    tools
  end

  def call_tool(this, name, input \\ nil, options \\ %{}) do
    %{result: result} =
      channel_call(
        this._frame,
        :webmcpCallTool,
        %{name: name, input: JSHandle.serialize_argument(input)},
        Frame._timeout(this._frame, options)
      )

    JSHandle.parse_result(result)
  end
end
