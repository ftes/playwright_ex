defmodule PlaywrightEx.Page.ExpectToHaveValueTest do
  @upstream "tests/page/expect-to-have-value.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  test "should work", %{page: page} do
    Page.set_content!(page, "<input id=node></input>")
    locator = Page.locator(page, "#node")
    Locator.fill!(locator, "Text content")
    Expect.to_have_value!(locator, "Text content")
  end

  test "should work with label", %{page: page} do
    Page.set_content!(page, "<label><input></input></label>")
    Locator.fill!(Page.locator(page, "label input"), "Text content")
    Expect.to_have_value!(Page.locator(page, "label"), "Text content")
  end

  test "should work with regex", %{page: page} do
    Page.set_content!(page, "<input id=node></input>")
    locator = Page.locator(page, "#node")
    Locator.fill!(locator, "Text content")
    Expect.to_have_value!(locator, ~r/Text/)
  end

  test "should support failure", %{page: page} do
    Page.set_content!(page, "<input id=node></input>")
    locator = Page.locator(page, "#node")
    Locator.fill!(locator, "Text content")
    {:error, error} = Expect.to_have_value(locator, ~r/Text2/, timeout: 1000)
    assert error.message =~ "\"Text content\""
  end

  describe "toHaveValues with multi-select" do
    test "works with text", %{page: page} do
      Page.set_content!(page, """
      <select multiple>
        <option value="R">Red</option>
        <option value="G">Green</option>
        <option value="B">Blue</option>
      </select>
      """)

      locator = Page.locator(page, "select")
      Locator.select_option!(locator, ["R", "G"])
      Expect.to_have_values!(locator, ["R", "G"])
    end

    test "follows labels", %{page: page} do
      Page.set_content!(page, """
      <label for="colors">Pick a Color</label>
      <select id="colors" multiple>
        <option value="R">Red</option>
        <option value="G">Green</option>
        <option value="B">Blue</option>
      </select>
      """)

      locator = Page.locator(page, "text=Pick a Color")
      Locator.select_option!(locator, ["R", "G"])
      Expect.to_have_values!(locator, ["R", "G"])
    end

    test "exact match with text failure", %{page: page} do
      Page.set_content!(page, """
      <select multiple>
        <option value="RR">Red</option>
        <option value="GG">Green</option>
      </select>
      """)

      locator = Page.locator(page, "select")
      Locator.select_option!(locator, ["RR", "GG"])
      {:error, error} = Expect.to_have_values(locator, ["R", "G"], timeout: 1000)
      assert error.message =~ "-   \"R\""
      assert error.message =~ "+   \"RR\""
    end

    test "works with regex", %{page: page} do
      Page.set_content!(page, """
      <select multiple>
        <option value="R">Red</option>
        <option value="G">Green</option>
        <option value="B">Blue</option>
      </select>
      """)

      locator = Page.locator(page, "select")
      Locator.select_option!(locator, ["R", "G"])
      Expect.to_have_values!(locator, [~r/R/, ~r/G/])
    end

    test "fails when items not selected", %{page: page} do
      Page.set_content!(page, """
      <select multiple>
        <option value="R">Red</option>
        <option value="G">Green</option>
        <option value="B">Blue</option>
      </select>
      """)

      locator = Page.locator(page, "select")
      Locator.select_option!(locator, ["B"])
      {:error, error} = Expect.to_have_values(locator, [~r/R/, ~r/G/], timeout: 1000)
      assert error.message =~ "+   \"B\""
    end

    test "fails when multiple not specified", %{page: page} do
      Page.set_content!(page, """
      <select>
        <option value="R">Red</option>
        <option value="G">Green</option>
        <option value="B">Blue</option>
      </select>
      """)

      locator = Page.locator(page, "select")
      Locator.select_option!(locator, ["B"])
      {:error, error} = Expect.to_have_values(locator, [~r/R/, ~r/G/], timeout: 1000)
      assert Exception.message(error) =~ "Not a select element with a multiple attribute"
    end

    test "fails when not a select element", %{page: page} do
      Page.set_content!(page, """
      <input value="foo" />
      """)

      locator = Page.locator(page, "input")
      {:error, error} = Expect.to_have_values(locator, [~r/R/, ~r/G/], timeout: 1000)
      assert Exception.message(error) =~ "Not a select element with a multiple attribute"
    end
  end
end
