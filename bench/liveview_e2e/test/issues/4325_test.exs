defmodule LiveViewE2E.Issues.Issue4325Test do
  use LiveViewE2E.Case

  # elementHandle.evaluate is inherited from JSHandle
  alias PlaywrightEx.JSHandle

  # https://github.com/phoenixframework/phoenix_live_view/issues/4325
  test "setting an id to its current value preserves the element across patches", %{page: page} do
    Page.goto!(page, "/issues/4325")
    sync_lv(page)

    hooked = Page.locator(page, "#hooked")
    original_element = Locator.element_handle!(hooked)

    Expect.to_have_text!(hooked, "count is 0")

    # expect.poll: to_pass with the expect timeout
    to_pass(
      fn ->
        assert Page.evaluate!(page, "() => window.issue4325Lifecycle") ==
                 %{"mounted" => 1, "updated" => 0, "destroyed" => 0}
      end,
      timeout: 5_000
    )

    page |> Page.get_by_role(:button, name: "Increment") |> Locator.click!()
    Expect.to_have_text!(hooked, "count is 1")
    sync_lv(page)

    assert JSHandle.evaluate!(original_element, "(element) => element.isConnected") ==
             true

    assert Page.evaluate!(page, "() => window.issue4325Lifecycle") == %{
             "mounted" => 1,
             "updated" => 1,
             "destroyed" => 0
           }
  end
end
