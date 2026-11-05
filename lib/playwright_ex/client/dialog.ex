defmodule PlaywrightEx.Client.Dialog do
  @upstream "packages/playwright-core/src/client/dialog.ts"
  @moduledoc "Port of `#{@upstream}`."
  use PlaywrightEx.Client.ChannelOwner, struct: PlaywrightEx.Dialog

  alias PlaywrightEx.Client.Errors
  alias PlaywrightEx.Client.Page

  def from(dialog) do
    dialog
  end

  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    # Note: dialogs that open early during page initialization block it.
    # Therefore, we must report the dialog without a page to be able to handle it.
    put(this, :_page, Page.from_nullable(initializer[:page]))
    this
  end

  def page(this) do
    get(this, :_page)
  end

  def type(this) do
    get(this, :_initializer).type
  end

  def message(this) do
    get(this, :_initializer).message
  end

  def default_value(this) do
    get(this, :_initializer).defaultValue
  end

  def accept(this, prompt_text \\ nil) do
    channel_call(this, :accept, %{promptText: prompt_text}, TimeoutSettings.k_no_timeout())
    nil
  end

  def dismiss(this) do
    try do
      channel_call(this, :dismiss, %{}, TimeoutSettings.k_no_timeout())
    rescue
      e -> if Errors.is_target_closed_error(e), do: nil, else: reraise(e, __STACKTRACE__)
    end

    nil
  end
end
