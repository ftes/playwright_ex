defmodule PlaywrightEx.Library.LoggerTest do
  @upstream "tests/library/logger.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Page

  # `log.push(...)`: an Agent holds the log.
  defp logger(log) do
    %{
      log: fn name, severity, message ->
        Agent.update(log, &(&1 ++ [%{name: name, severity: severity, message: message}]))
      end,
      isEnabled: fn _name, severity -> severity != "verbose" end
    }
  end

  test "LG-001 should log @smoke", %{browser_type: browser_type} do
    log = start_supervised!({Agent, fn -> [] end})
    browser = BrowserType.launch!(browser_type, logger: logger(log))
    Browser.new_context!(browser)
    Browser.close!(browser)
    log = Agent.get(log, & &1)
    assert Enum.find(log, &(&1.severity == "info"))
    assert Enum.find(log, &String.contains?(&1.message, "browser.newContext started"))
    assert Enum.find(log, &String.contains?(&1.message, "browser.newContext succeeded"))
  end

  test "LG-002 should log context-level", %{browser_type: browser_type} do
    log = start_supervised!({Agent, fn -> [] end})
    browser = BrowserType.launch!(browser_type)
    context = Browser.new_context!(browser, logger: logger(log))
    page = BrowserContext.new_page!(context)
    Page.set_content!(page, "<button>Button</button>")
    Page.click!(page, "button")
    Browser.close!(browser)

    log = Agent.get(log, & &1)
    assert log != []
    assert Enum.any?(log, &String.contains?(&1.message, "page.setContent"))
    assert Enum.any?(log, &String.contains?(&1.message, "page.click"))
  end
end
