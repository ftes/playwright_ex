defmodule PlaywrightEx.Library.PageClockFrozenTest do
  @upstream "tests/library/page-clock.frozen.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Page

  @moduletag :page

  # it.skip(process.env.PW_CLOCK !== 'frozen'): the harness has no PW_CLOCK modes (browserTest.ts's
  # `_contextFactory` installs the clock)
  @tag skip: "not ported: no frozen-clock mode"
  test "clock should be frozen", %{page: page} do
    assert Page.evaluate!(page, "Date.now()") == 1000
  end

  # it.skip(process.env.PW_CLOCK !== 'realtime')
  @tag skip: "not ported: no realtime-clock mode"
  test "clock should be realtime", %{page: page} do
    assert Page.evaluate!(page, "Date.now()") < 10_000
  end
end
