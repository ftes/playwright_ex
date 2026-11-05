defmodule PlaywrightEx.Library.PageClockFrozenTest do
  @upstream "tests/library/page-clock.frozen.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  # it.skip(process.env.PW_CLOCK !== 'frozen')
  @tag skip: if(System.get_env("PW_CLOCK") != "frozen", do: "upstream skip: PW_CLOCK is not frozen")
  test "clock should be frozen", %{page: page} do
    assert Page.evaluate!(page, "Date.now()") == 1000
  end

  # it.skip(process.env.PW_CLOCK !== 'realtime')
  @tag skip: if(System.get_env("PW_CLOCK") != "realtime", do: "upstream skip: PW_CLOCK is not realtime")
  test "clock should be realtime", %{page: page} do
    assert Page.evaluate!(page, "Date.now()") < 10_000
  end
end
