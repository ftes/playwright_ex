defmodule Playwright.DisposableTest do
  # Elixir only: both client classes behind one handle struct (`Playwright.Client.Disposable`).
  use ExUnit.Case, async: true

  alias Playwright.Browser
  alias Playwright.BrowserType
  alias Playwright.Client.ChannelOwner
  alias Playwright.Client.DisposableObject
  alias Playwright.Client.DisposableStub
  alias Playwright.Disposable
  alias Playwright.Locator
  alias Playwright.Page
  alias Playwright.Runtime.Heap
  alias Playwright.TestBrowser

  setup_all do
    start_supervised!({Playwright.Supervisor, name: __MODULE__})
    browser = BrowserType.launch!(TestBrowser.browser_type(Playwright.instance(__MODULE__)))
    on_exit(fn -> Browser.close(browser) end)
    %{browser: browser}
  end

  test "a channel object is a disposable handle", %{browser: browser} do
    page = Browser.new_page!(browser)
    disposable = Page.add_init_script!(page, "window.injected = 1")

    assert %Disposable{} = disposable
    assert Heap.impl(disposable) == DisposableObject
    assert ChannelOwner.is_channel_owner(disposable)
    assert inspect(disposable) =~ "#Playwright.Disposable<"
    assert Disposable.dispose!(disposable) == :ok
  end

  test "a stub is a disposable handle", %{browser: browser} do
    page = Browser.new_page!(browser)
    Page.set_content!(page, "<button>Hi</button>")
    disposable = page |> Page.locator("button") |> Locator.highlight!()

    assert %Disposable{} = disposable
    assert Heap.impl(disposable) == DisposableStub
    refute ChannelOwner.is_channel_owner(disposable)
    assert inspect(disposable) =~ "#Playwright.Disposable<"
    assert Disposable.dispose!(disposable) == :ok
    assert Disposable.dispose!(disposable) == :ok
  end
end
