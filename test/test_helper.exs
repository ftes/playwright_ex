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

# Headed windows steal focus on macOS: `mix test --include headed` runs them (PORTING "Tests").
if match?({:unix, :darwin}, :os.type()), do: ExUnit.configure(exclude: [:headed])

ExUnit.start(
  assert_receive_timeout: 10_000,
  max_cases: max_cases,
  formatters: [ExUnit.CLIFormatter, PlaywrightEx.FailuresFormatter]
)
