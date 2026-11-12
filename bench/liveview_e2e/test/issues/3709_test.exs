defmodule LiveViewE2E.Issues.Issue3709Test do
  use LiveViewE2E.Case

  # https://github.com/phoenixframework/phoenix_live_view/issues/3709
  test "pendingDiffs don't race with navigation", %{page: page} do
    {:ok, logs} = Agent.start_link(fn -> [] end)
    Page.on(page, :console, fn e -> Agent.update(logs, &(&1 ++ [ConsoleMessage.text(e)])) end)
    {:ok, errors} = Agent.start_link(fn -> [] end)
    Page.on(page, :page_error, fn err -> Agent.update(errors, &(&1 ++ [err])) end)

    Page.goto!(page, "/issues/3709/1")
    sync_lv(page)
    page |> Page.locator("body") |> Expect.to_contain_text!("id: 1")

    page |> Page.get_by_role(:button, name: "Break Stuff") |> Locator.click!()
    sync_lv(page)

    # expect.stringMatching(string) compiles the string as a RegExp
    refute Enum.any?(
             Agent.get(logs, & &1),
             &(&1 =~ ~r/Cannot read properties of undefined (reading 's')/)
           )

    page |> Page.get_by_role(:link, name: "Link 5") |> Locator.click!()
    sync_lv(page)
    page |> Page.locator("body") |> Expect.to_contain_text!("id: 5")

    refute Enum.any?(
             Agent.get(logs, & &1),
             &(&1 =~ ~r/Cannot set properties of undefined (setting 'newRender')/)
           )

    # no uncaught exceptions
    assert Agent.get(errors, & &1) == []
  end
end
