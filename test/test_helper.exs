Logger.configure(level: :info)
# Upstream's tests/library/playwright.config.ts `expect: { timeout: 10000 }`.
Application.put_env(:playwright_ex, :expect, timeout: 10_000)
# Upstream awaits events with no timeout of its own (bounded by the test timeout); ExUnit's
# 100 ms `assert_receive` default flakes on slow CI runners. As many modules at once as upstream
# runs workers (Playwright's default: half the logical cores), or `PW_MAX_CASES`.
max_cases =
  case System.get_env("PW_MAX_CASES", "") do
    "" -> max(div(System.schedulers_online(), 2), 1)
    value -> String.to_integer(value)
  end

# `PlaywrightEx.Test`, which every case template gets its browser from (`UpstreamCase`,
# `ExampleCase`, its own tests in test/playwright_ex/test): the browser under test, artifacts
# outside the checkout, and a worker for each module running at once.
Application.put_env(:playwright_ex, :test,
  browser_name: String.to_atom(PlaywrightEx.TestBrowser.name()),
  output_dir: Path.join(System.tmp_dir!(), "playwright_ex-test-results"),
  workers: max_cases
)

# Headed windows steal focus on macOS: `mix test --include headed` runs them (PORTING "Tests").
# Stress and perf tests are manual only (`mix test --only stress`, `--only perf`), not run by CI.
exclude = [:stress, :perf]
exclude = if match?({:unix, :darwin}, :os.type()), do: [:headed | exclude], else: exclude
ExUnit.configure(exclude: exclude)

# Our own tests (not mirrored from upstream, which get upstream's 30 s): tight, so a hang fails
# fast. The slowest takes ~5 s (a 5 s navigation timeout) on each browser (2026-11-05, macOS);
# longer ones carry their own `@tag timeout:` with the measurement.
ExUnit.start(
  timeout: 20_000,
  assert_receive_timeout: 10_000,
  max_cases: max_cases,
  formatters: [ExUnit.CLIFormatter, PlaywrightEx.FailuresFormatter, PlaywrightEx.ModuleTimesFormatter]
)

# The artifacts dirs of `PlaywrightEx.UpstreamCase`'s drivers. Registered first, so it runs after
# `PlaywrightEx.Test` stops the drivers.
ExUnit.after_suite(fn _ -> File.rm_rf(PlaywrightEx.UpstreamCase.artifacts_root()) end)
