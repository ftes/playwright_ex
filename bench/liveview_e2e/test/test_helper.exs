# Playwright Test's defaults: `workers` half the cores, a 30 s test timeout.
max_cases =
  case System.get_env("PW_MAX_CASES", "") do
    "" -> max(div(System.schedulers_online(), 2), 1)
    value -> String.to_integer(value)
  end

Application.put_env(
  :playwright_ex,
  :test,
  Keyword.put(Application.get_env(:playwright_ex, :test), :workers, max_cases)
)

ExUnit.start(max_cases: max_cases, timeout: 30_000)
