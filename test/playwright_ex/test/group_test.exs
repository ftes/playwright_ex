# The guide's recipe for a few Firefox modules: modules of one ExUnit `group:` share a browser
# and never run at once (here on the browser under test).
for name <- [PlaywrightEx.Test.GroupTest.A, PlaywrightEx.Test.GroupTest.B] do
  defmodule name do
    use ExUnit.Case, async: true, group: :playwright_ex_group_test

    import PlaywrightEx.Test

    alias PlaywrightEx.Page

    setup_all :browser
    setup [:new_context, :new_page]

    test "shares the browser and runs alone", %{browser: browser, page: page} do
      # A table of the group's (owned by the first module's test that makes it).
      table =
        try do
          :ets.new(:playwright_ex_group_test, [:named_table, :public])
        rescue
          ArgumentError -> :playwright_ex_group_test
        end

      first = :persistent_term.get({PlaywrightEx.Test.GroupTest, :browser}, browser)
      :persistent_term.put({PlaywrightEx.Test.GroupTest, :browser}, first)
      assert browser == first

      assert :ets.update_counter(table, :running, 1, {:running, 0}) == 1
      Page.set_content!(page, "<button>Go</button>")
      Process.sleep(300)
      assert :ets.update_counter(table, :running, -1) == 0
    end
  end
end
