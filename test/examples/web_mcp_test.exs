defmodule PlaywrightEx.Examples.WebMCPTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.TestBrowser
  alias PlaywrightEx.WebMCP

  @chromium_only if(TestBrowser.name() != "chromium", do: "launches chromium, not the browser under test")

  @add_tool ~S"""
  <script>
    (document.modelContext || navigator.modelContext).registerTool({
      name: 'add',
      description: 'Adds two numbers',
      inputSchema: { type: 'object', properties: { a: { type: 'number' }, b: { type: 'number' } } },
      async execute({ a, b }) { return { content: [{ type: 'text', text: String(a + b) }] }; },
    });
  </script>
  """

  example "WebMCP",
    js: ~S"""
    const browser = await chromium.launch({ args: ['--enable-features=WebMCP'] });
    const page = await browser.newPage();
    await page.goto('https://example.com');

    for (const tool of await page.webmcp.tools())
      console.log(tool.name, tool.description);

    const result = await page.webmcp.callTool('add', { a: 2, b: 40 });
    """,
    html: @add_tool,
    skip: @chromium_only do
    browser = Playwright.chromium(playwright) |> BrowserType.launch!(args: ["--enable-features=WebMCP"])
    page = Browser.new_page!(browser)
    Page.goto!(page, "https://example.com")

    for tool <- Page.webmcp(page) |> WebMCP.tools!() do
      IO.puts("#{tool.name} #{tool.description}")
    end

    result = Page.webmcp(page) |> WebMCP.call_tool!("add", %{a: 2, b: 40})
  end

  example "WebMCP.callTool",
    js: ~S"""
    const result = await page.webmcp.callTool('add', { a: 2, b: 40 });
    console.log(result.content[0].text); // "42"
    """,
    html: @add_tool,
    skip: if(TestBrowser.name() == "webkit", do: "WebKit does not implement WebMCP"),
    given: [page: webmcp_page(playwright)] do
    result = Page.webmcp(page) |> WebMCP.call_tool!("add", %{a: 2, b: 40})
    # prints 42
    IO.puts(hd(result["content"])["text"])
  end

  # A page of a browser launched with WebMCP enabled, at the example's `html:`.
  defp webmcp_page(playwright) do
    browser_type = TestBrowser.browser_type(playwright)

    browser =
      if TestBrowser.name() == "firefox",
        do:
          BrowserType.launch!(browser_type,
            firefox_user_prefs: %{"dom.modelcontext.enabled" => true, "dom.modelcontext.testing.enabled" => true}
          ),
        else: BrowserType.launch!(browser_type, args: ["--enable-features=WebMCP"])

    page = Browser.new_page!(browser)
    Page.goto!(page, "https://example.com/")
    page
  end
end
