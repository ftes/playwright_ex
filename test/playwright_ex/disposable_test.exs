defmodule PlaywrightEx.DisposableTest do
  # Elixir only: both client classes behind one handle struct (`PlaywrightEx.Client.Disposable`).
  use ExUnit.Case, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Client.ChannelOwner
  alias PlaywrightEx.Client.DisposableObject
  alias PlaywrightEx.Client.DisposableStub
  alias PlaywrightEx.Disposable
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime.Heap
  alias PlaywrightEx.TestBrowser

  setup_all do
    start_supervised!({PlaywrightEx.Supervisor, name: __MODULE__})
    browser = BrowserType.launch!(TestBrowser.browser_type(PlaywrightEx.playwright(__MODULE__)))
    on_exit(fn -> Browser.close(browser) end)
    %{browser: browser}
  end

  test "a channel object is a disposable handle", %{browser: browser} do
    page = Browser.new_page!(browser)
    disposable = Page.add_init_script!(page, "window.injected = 1")

    assert %Disposable{} = disposable
    assert Heap.impl(disposable) == DisposableObject
    assert ChannelOwner.is_channel_owner(disposable)
    assert inspect(disposable) =~ "#PlaywrightEx.Disposable<"
    assert Disposable.dispose!(disposable) == :ok
  end

  test "a stub is a disposable handle", %{browser: browser} do
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<button>Hi</button>")
    disposable = page |> Page.locator("button") |> Locator.highlight!()

    assert %Disposable{} = disposable
    assert Heap.impl(disposable) == DisposableStub
    refute ChannelOwner.is_channel_owner(disposable)
    assert inspect(disposable) =~ "#PlaywrightEx.Disposable<"
    assert Disposable.dispose!(disposable) == :ok
    assert Disposable.dispose!(disposable) == :ok
  end
end
