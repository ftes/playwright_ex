Logger.configure(level: :info)
# Upstream's tests/library/playwright.config.ts `expect: { timeout: 10000 }` (module state, as in JS).
PlaywrightEx.Matchers.Expect.set_expect_config(Map.put(PlaywrightEx.Matchers.Expect.expect_config(), :timeout, 10_000))
ExUnit.start()
