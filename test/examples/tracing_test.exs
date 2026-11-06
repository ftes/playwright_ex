defmodule PlaywrightEx.Examples.TracingTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Tracing

  @chromium_only if(PlaywrightEx.TestBrowser.name() != "chromium", do: "launches chromium, not the browser under test")

  example "Tracing",
    js: ~S"""
    const browser = await chromium.launch();
    const context = await browser.newContext();
    await context.tracing.start({ screenshots: true, snapshots: true });
    const page = await context.newPage();
    await page.goto('https://playwright.dev');
    expect(page.url()).toBe('https://playwright.dev');
    await context.tracing.stop({ path: 'trace.zip' });
    """,
    writes: ["trace.zip"],
    skip: @chromium_only do
    browser = Playwright.chromium(playwright) |> BrowserType.launch!()
    context = Browser.new_context!(browser)
    BrowserContext.tracing(context) |> Tracing.start!(screenshots: true, snapshots: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://playwright.dev")
    assert Page.url(page) == "https://playwright.dev/"
    BrowserContext.tracing(context) |> Tracing.stop!(path: "trace.zip")
  end

  example "Tracing.start",
    js: ~S"""
    await context.tracing.start({ screenshots: true, snapshots: true });
    const page = await context.newPage();
    await page.goto('https://playwright.dev');
    expect(page.url()).toBe('https://playwright.dev');
    await context.tracing.stop({ path: 'trace.zip' });
    """,
    writes: ["trace.zip"] do
    BrowserContext.tracing(context) |> Tracing.start!(screenshots: true, snapshots: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://playwright.dev")
    assert Page.url(page) == "https://playwright.dev/"
    BrowserContext.tracing(context) |> Tracing.stop!(path: "trace.zip")
  end

  example "Tracing.startChunk",
    js: ~S"""
    await context.tracing.start({ screenshots: true, snapshots: true });
    const page = await context.newPage();
    await page.goto('https://playwright.dev');

    await context.tracing.startChunk();
    await page.getByText('Get Started').click();
    // Everything between startChunk and stopChunk will be recorded in the trace.
    await context.tracing.stopChunk({ path: 'trace1.zip' });

    await context.tracing.startChunk();
    await page.goto('http://example.com');
    // Save a second trace file with different actions.
    await context.tracing.stopChunk({ path: 'trace2.zip' });
    """,
    html: ~s(<a href="/docs/intro">Get Started</a>),
    writes: ["trace1.zip", "trace2.zip"] do
    BrowserContext.tracing(context) |> Tracing.start!(screenshots: true, snapshots: true)
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://playwright.dev")

    BrowserContext.tracing(context) |> Tracing.start_chunk!()
    Page.get_by_text(page, "Get Started") |> Locator.click!()
    # Everything between start_chunk and stop_chunk will be recorded in the trace.
    BrowserContext.tracing(context) |> Tracing.stop_chunk!(path: "trace1.zip")

    BrowserContext.tracing(context) |> Tracing.start_chunk!()
    Page.goto!(page, "http://example.com")
    # Save a second trace file with different actions.
    BrowserContext.tracing(context) |> Tracing.stop_chunk!(path: "trace2.zip")
  end

  example "Tracing.startHar",
    js: ~S"""
    await context.tracing.startHar('trace.har');
    const page = await context.newPage();
    await page.goto('https://playwright.dev');
    await context.tracing.stopHar();
    """,
    writes: ["trace.har"] do
    BrowserContext.tracing(context) |> Tracing.start_har!("trace.har")
    page = BrowserContext.new_page!(context)
    Page.goto!(page, "https://playwright.dev")
    BrowserContext.tracing(context) |> Tracing.stop_har!()
  end

  # JS points to test.step; the library's group/group_end is Python's example.
  example "Tracing.group",
    js: ~S"""
    // use test.step instead
    await test.step('Log in', async () => {
      // ...
    });
    """,
    html: ~s(<a href="/docs/api/class-playwright">API</a>) do
    # All actions between group and group_end
    # will be shown in the trace viewer as a group.
    Page.context(page) |> BrowserContext.tracing() |> Tracing.group!("Open Playwright.dev > API")
    Page.goto!(page, "https://playwright.dev/")
    Page.get_by_role(page, :link, name: "API") |> Locator.click!()
    Page.context(page) |> BrowserContext.tracing() |> Tracing.group_end!()
  end
end
