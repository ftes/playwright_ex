# The guide's recipe for a few Firefox modules: modules of one ExUnit `group:` never run at once,
# so a shared browser serves one of them at a time (here the browser under test).
for name <- [PlaywrightEx.Test.GroupTest.A, PlaywrightEx.Test.GroupTest.B] do
  defmodule name do
    use ExUnit.Case, async: true, group: :playwright_ex_group_test

    use PlaywrightEx.Test

    alias PlaywrightEx.Page

    setup_all :browser
    setup [:new_context, :new_page]

    test "runs alone", %{page: page} do
      # A table of the group's (owned by the first module's test that makes it).
      table =
        try do
          :ets.new(:playwright_ex_group_test, [:named_table, :public])
        rescue
          ArgumentError -> :playwright_ex_group_test
        end

      assert :ets.update_counter(table, :running, 1, {:running, 0}) == 1
      Page.set_content!(page, "<button>Go</button>")
      Process.sleep(300)
      assert :ets.update_counter(table, :running, -1) == 0
    end
  end
end
