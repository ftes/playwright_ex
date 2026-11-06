defmodule PlaywrightEx.Client.Credentials do
  @upstream "packages/playwright-core/src/client/credentials.ts"
  @moduledoc "Port of `#{@upstream}`. No mutable state: a plain struct."
  import PlaywrightEx.Client.ChannelOwner, only: [channel_call: 4]

  alias PlaywrightEx.Client.TimeoutSettings

  # Elixir only: the handle is the facade's struct, `%PlaywrightEx.Credentials{}` (gen.api copies these fields).
  @doc false
  def __struct_fields__, do: [:_browserContext]

  def new(browser_context) do
    %PlaywrightEx.Credentials{_browserContext: browser_context}
  end

  def install(this) do
    channel_call(this._browserContext, :credentialsInstall, %{}, TimeoutSettings.k_no_timeout())
    nil
  end

  def create(this, rp_id, options \\ %{}) do
    %{credential: credential} =
      channel_call(
        this._browserContext,
        :credentialsCreate,
        Map.merge(options || %{}, %{rpId: rp_id}),
        TimeoutSettings.k_no_timeout()
      )

    credential
  end

  def get(this, options \\ %{}) do
    %{credentials: credentials} =
      channel_call(this._browserContext, :credentialsGet, options || %{}, TimeoutSettings.k_no_timeout())

    credentials
  end

  def delete(this, id) do
    channel_call(this._browserContext, :credentialsDelete, %{id: id}, TimeoutSettings.k_no_timeout())
    nil
  end
end
