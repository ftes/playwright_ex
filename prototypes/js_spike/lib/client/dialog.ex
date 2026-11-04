# upstream: packages/playwright-core/src/client/dialog.ts
defmodule PlaywrightJS.Client.Dialog do
  use PlaywrightJS.Client.ChannelOwner
  alias PlaywrightJS.Client.{Errors, Page}

  # upstream: dialog.ts:25
  def from(dialog) do
    dialog
  end

  # upstream: dialog.ts:31
  def new(parent, type, guid, initializer) do
    this = ChannelOwner.new(__MODULE__, parent, type, guid, initializer)
    # Note: dialogs that open early during page initialization block it.
    # Therefore, we must report the dialog without a page to be able to handle it.
    put(this, :_page, Page.from_nullable(initializer[:page]))
    this
  end

  # upstream: dialog.ts:38
  def page(this) do
    get(this, :_page)
  end

  # upstream: dialog.ts:42
  def type(this) do
    get(this, :_initializer).type
  end

  # upstream: dialog.ts:46
  def message(this) do
    get(this, :_initializer).message
  end

  # upstream: dialog.ts:50
  def default_value(this) do
    get(this, :_initializer).defaultValue
  end

  # upstream: dialog.ts:54
  def accept(this, prompt_text \\ nil) do
    channel_call(this, :accept, %{promptText: prompt_text}, TimeoutSettings.k_no_timeout())
    nil
  end

  # upstream: dialog.ts:58
  def dismiss(this) do
    try do
      channel_call(this, :dismiss, %{}, TimeoutSettings.k_no_timeout())
      nil
    rescue
      e -> if Errors.is_target_closed_error(e), do: nil, else: reraise(e, __STACKTRACE__)
    end
  end
end
