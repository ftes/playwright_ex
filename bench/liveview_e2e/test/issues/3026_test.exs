defmodule LiveViewE2E.Issues.Issue3026Test do
  use LiveViewE2E.Case

  test "LiveComponent is re-rendered when racing destory", %{page: page} do
    {:ok, errors} = Agent.start(fn -> [] end)

    Page.on(page, :page_error, fn err ->
      Agent.update(errors, &(&1 ++ [err]))
    end)

    Page.goto!(page, "/issues/3026")
    sync_lv(page)

    page |> Page.locator("input[name='name']") |> Expect.to_have_value!("John")

    # submitting the form unloads the LiveComponent, but it is re-added shortly after
    page |> Page.locator("button") |> Locator.click!()
    sync_lv(page)

    # the form elements inside the LC should still be visible
    page |> Page.locator("input[name='name']") |> Expect.to_be_visible!()
    page |> Page.locator("input[name='name']") |> Expect.to_have_value!("John")

    # quickly toggle status
    for _i <- 0..4 do
      page |> Page.locator("select[name='status']") |> Locator.select_option!("connecting")
      sync_lv(page)
      # now the form is not rendered as status is connecting
      page |> Page.locator("input[name='name']") |> Expect.to_be_hidden!()

      # set back to loading
      page |> Page.locator("select[name='status']") |> Locator.select_option!("loaded")
      sync_lv(page)
      # now the form is not rendered as status is connecting
      page |> Page.locator("input[name='name']") |> Expect.to_be_visible!()
    end

    # no js errors should be thrown
    assert Agent.get(errors, & &1) == []
  end
end
