Logger.configure(level: :info)
# Upstream's tests/library/playwright.config.ts `expect: { timeout: 10000 }`.
Application.put_env(:playwright_ex, :expect, timeout: 10_000)
ExUnit.start()
