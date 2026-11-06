defmodule PlaywrightEx.Examples.ClockTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Clock

  example "Clock.fastForward",
    js: ~S"""
    await page.clock.fastForward(1000);
    await page.clock.fastForward('30:00');
    """ do
    Page.clock(page) |> Clock.fast_forward!(1000)
    Page.clock(page) |> Clock.fast_forward!("30:00")
  end

  example "Clock.runFor",
    js: ~S"""
    await page.clock.runFor(1000);
    await page.clock.runFor('30:00');
    """ do
    Page.clock(page) |> Clock.run_for!(1000)
    Page.clock(page) |> Clock.run_for!("30:00")
  end

  example "Clock.pauseAt",
    js: ~S"""
    await page.clock.pauseAt(new Date('2020-02-02'));
    await page.clock.pauseAt('2020-02-02');
    """ do
    Page.clock(page) |> Clock.pause_at!(~U[2020-02-02 00:00:00Z])
    Page.clock(page) |> Clock.pause_at!("2020-02-02")
  end

  example "Clock.pauseAt",
    js: ~S"""
    // Initialize clock with some time before the test time and let the page load
    // naturally. `Date.now` will progress as the timers fire.
    await page.clock.install({ time: new Date('2024-12-10T08:00:00') });
    await page.goto('http://localhost:3333');
    await page.clock.pauseAt(new Date('2024-12-10T10:00:00'));
    """ do
    # Initialize clock with some time before the test time and let the page load
    # naturally. `Date.now` will progress as the timers fire.
    Page.clock(page) |> Clock.install!(time: ~U[2024-12-10 08:00:00Z])
    Page.goto!(page, "http://localhost:3333")
    Page.clock(page) |> Clock.pause_at!(~U[2024-12-10 10:00:00Z])
  end

  example "Clock.setFixedTime",
    js: ~S"""
    await page.clock.setFixedTime(Date.now());
    await page.clock.setFixedTime(new Date('2020-02-02'));
    await page.clock.setFixedTime('2020-02-02');
    """ do
    Page.clock(page) |> Clock.set_fixed_time!(DateTime.utc_now())
    Page.clock(page) |> Clock.set_fixed_time!(~U[2020-02-02 00:00:00Z])
    Page.clock(page) |> Clock.set_fixed_time!("2020-02-02")
  end

  example "Clock.setSystemTime",
    js: ~S"""
    await page.clock.setSystemTime(Date.now());
    await page.clock.setSystemTime(new Date('2020-02-02'));
    await page.clock.setSystemTime('2020-02-02');
    """ do
    Page.clock(page) |> Clock.set_system_time!(DateTime.utc_now())
    Page.clock(page) |> Clock.set_system_time!(~U[2020-02-02 00:00:00Z])
    Page.clock(page) |> Clock.set_system_time!("2020-02-02")
  end
end
