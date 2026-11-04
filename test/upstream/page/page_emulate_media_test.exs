defmodule PlaywrightEx.Page.PageEmulateMediaTest do
  @upstream "tests/page/page-emulate-media.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  # expect.extend({ toMatchMedia })
  defp matches_media?(page, media_query) do
    case Page.evaluate(page, "mediaQuery => matchMedia(mediaQuery).matches", media_query) do
      {:ok, pass} -> pass
      {:error, _} -> false
    end
  end

  @tag skip: "not ported: Page.emulateMedia"
  test "should emulate type @smoke"

  @tag skip: "not ported: Page.emulateMedia"
  test "should throw in case of bad media argument"

  @tag skip: "not ported: Page.emulateMedia"
  test "should emulate colorScheme should work @smoke"

  @tag skip: "not ported: Page.emulateMedia"
  test "should default to light"

  @tag skip: "not ported: Page.emulateMedia"
  test "should throw in case of bad colorScheme argument"

  @tag skip: "not ported: Page.emulateMedia"
  test "should work during navigation"

  @tag skip: "not ported: Page.emulateMedia"
  test "should change the actual colors in css"

  @tag skip: "not ported: Page.emulateMedia"
  test "should emulate reduced motion"

  @tag skip: "not ported: Page.emulateMedia"
  test "should keep reduced motion and color emulation after reload"

  @tag skip: "not ported: Page.emulateMedia"
  test "should emulate forcedColors "

  @tag skip: "not ported: Page.emulateMedia"
  test "should emulate contrast "

  test "should report hover and fine pointer for desktop", %{page: page} do
    assert matches_media?(page, "(hover: hover)"), ~s|Expected "(hover: hover)" to match, but it did not|
    assert matches_media?(page, "(pointer: fine)"), ~s|Expected "(pointer: fine)" to match, but it did not|
  end
end
