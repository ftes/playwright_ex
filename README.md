[![Hex.pm Version](https://img.shields.io/hexpm/v/playwright_ex)](https://hex.pm/packages/playwright_ex)
[![Hex Docs](https://img.shields.io/badge/hex-docs-lightgreen.svg)](https://hexdocs.pm/playwright_ex/)
[![License](https://img.shields.io/hexpm/l/playwright_ex.svg)](https://github.com/ftes/playwright_ex/blob/main/LICENSE.md)
[![GitHub Actions Workflow Status](https://img.shields.io/github/actions/workflow/status/ftes/playwright_ex/elixir.yml)](https://github.com/ftes/playwright_ex/actions)

# PlaywrightEx

Elixir client for Playwright: a 1:1 port of the official JavaScript client, with the public API
generated from upstream's docs, so the [playwright.dev](https://playwright.dev/docs/api/class-playwright)
docs apply. Coming from 0.x? See the [migration guide](guides/migration.md).

```elixir
alias PlaywrightEx.{Browser, BrowserType, Expect, Locator, Page, Playwright}

{:ok, _} = PlaywrightEx.Supervisor.start_link()
browser = BrowserType.launch!(Playwright.chromium(PlaywrightEx.playwright()))
page = Browser.new_page!(browser)
Page.goto!(page, "https://elixir-lang.org/")
Page.get_by_role(page, :link, name: "Install") |> Locator.click!()
Expect.to_have_title!(page, ~r/Install/)
```

The pinned driver (Node and `playwright-core`) downloads on first start, or with
`mix playwright_ex.install`.

## Contributing

1. `mix setup` installs dependencies, the pinned Playwright driver and Chromium.
2. `mix test`, or `mix check` for everything CI runs.
