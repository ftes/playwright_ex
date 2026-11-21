Logger.configure(level: :info)
# Upstream's tests/library/playwright.config.ts `expect: { timeout: 10000 }`.
Application.put_env(:playwright, :expect, timeout: 10_000)
# Upstream awaits events with no timeout of its own (bounded by the test timeout); ExUnit's
# 100 ms `assert_receive` default flakes on slow CI runners. As many modules at once as upstream
# runs workers (Playwright's default: half the logical cores), or `PW_MAX_CASES`.
max_cases =
  case System.get_env("PW_MAX_CASES", "") do
    "" -> max(div(System.schedulers_online(), 2), 1)
    value -> String.to_integer(value)
  end

# `Playwright.Test`, which every case template gets its browser from (`UpstreamCase`,
# `ExampleCase`, its own tests in test/playwright/test): the browser under test, artifacts
# outside the checkout, and a worker for each module running at once.
Application.put_env(:playwright, :test,
  browser_name: String.to_atom(Playwright.TestBrowser.name()),
  output_dir: Path.join(System.tmp_dir!(), "playwright-test-results"),
  workers: max_cases
)

# Headed windows steal focus on macOS: `mix test --include headed` runs them (PORTING "Tests").
# Stress and perf tests are manual only (`mix test --only stress`, `--only perf`), not run by CI.
exclude = [:stress, :perf]
exclude = if match?({:unix, :darwin}, :os.type()), do: [:headed | exclude], else: exclude
ExUnit.configure(exclude: exclude)

# Our own tests (not mirrored from upstream, which get upstream's 30 s): tight, so a hang fails
# fast. The slowest takes ~5 s (a 5 s navigation timeout) on each browser (2026-11-05, macOS);
# longer ones carry their own `@tag timeout:` with the measurement. CI sets PW_GITHUB_FORMATTER
# for GitHub Actions annotations, on its rerun of the failures too.
ExUnit.start(
  timeout: 20_000,
  assert_receive_timeout: 10_000,
  max_cases: max_cases,
  formatters:
    [ExUnit.CLIFormatter, Playwright.FailuresFormatter, Playwright.ModuleTimesFormatter] ++
      if(System.get_env("PW_GITHUB_FORMATTER", "") != "", do: [Playwright.Test.GitHubFormatter], else: [])
)

# The artifacts dirs of `Playwright.UpstreamCase`'s drivers. Registered first, so it runs after
# `Playwright.Test` stops the drivers.
ExUnit.after_suite(fn _ -> File.rm_rf(Playwright.UpstreamCase.artifacts_root()) end)
