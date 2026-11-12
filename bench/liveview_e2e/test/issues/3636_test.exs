defmodule LiveViewE2E.Issues.Issue3636Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/3636
  test "focus_wrap - focuses first element when entering focus from outside", %{
    page: page,
    browser_name: browser_name
  } do
    # skip if webkit, since it doesn't have tab focus enabled by default
    # (test.skip(): ExUnit has no runtime skip, the test passes without running)
    if browser_name != :webkit do
      Page.goto!(page, "/issues/3636")
      sync_lv(page)
      # put focus next to the third button
      page |> Page.mouse() |> Mouse.click!(250, 37.5)
      page |> Page.keyboard() |> Keyboard.press!("Tab")
      page |> Page.get_by_role(:button, name: "One") |> Expect.to_be_focused!()
    end
  end
end
