defmodule PlaywrightEx.Library.WebmcpTest do
  @upstream "tests/library/webmcp.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  @browser_name System.get_env("BROWSER", "chromium")

  alias PlaywrightEx.BrowserType
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.WebMCP

  @moduletag :page
  @webkit_skip if(System.get_env("BROWSER") == "webkit", do: "upstream skip: WebKit does not implement WebMCP")
  @moduletag skip: @webkit_skip
  # test.skip(({ isBidi }) => isBidi, 'WebMCP is not implemented over BiDi');

  # test.use({ launchOptions }): this module's `browser` is launched with WebMCP enabled.
  setup_all %{browser_type: browser_type, browser_name: browser_name} do
    browser =
      if browser_name == "firefox",
        do:
          BrowserType.launch!(browser_type,
            firefox_user_prefs: %{"dom.modelcontext.enabled" => true, "dom.modelcontext.testing.enabled" => true}
          ),
        else: BrowserType.launch!(browser_type, args: ["--enable-features=WebMCP"])

    %{browser: browser}
  end

  defp register_script(tools) do
    """
    <script>
      const modelContext = document.modelContext || navigator.modelContext;
      #{tools}
    </script>
    """
  end

  @k_add """
    modelContext.registerTool({
      name: 'add',
      description: 'Adds two numbers',
      inputSchema: { type: 'object', properties: { a: { type: 'number' }, b: { type: 'number' } }, required: ['a', 'b'] },
      annotations: { readOnlyHint: true },
      async execute(input) { return { content: [{ type: 'text', text: String(input.a + input.b) }] }; },
    });
  """

  # `inputSchema` is JSON as the driver sends it (string keys).
  @k_add_schema %{
    "type" => "object",
    "properties" => %{"a" => %{"type" => "number"}, "b" => %{"type" => "number"}},
    "required" => ["a", "b"]
  }

  defp serve(server, path, body) do
    TestServer.set_route(server, path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "text/html")
      |> Plug.Conn.send_resp(200, "<title>WebMCP</title>#{body}")
    end)
  end

  defp text_content(text), do: %{"content" => [%{"type" => "text", "text" => text}]}

  test "WM-001 should list tools registered by the page", %{page: page, server: server} do
    serve(
      server,
      "/",
      register_script(
        @k_add <>
          """
            modelContext.registerTool({
              name: 'noop',
              description: 'Does nothing',
              async execute() {},
            });
          """
      )
    )

    Page.goto!(page, server.prefix <> "/")

    # Browsers list tools in their own order.
    tools = page |> Page.webmcp() |> WebMCP.tools!() |> Enum.sort_by(& &1.name)

    assert tools == [
             %{
               name: "add",
               description: "Adds two numbers",
               inputSchema: @k_add_schema,
               annotations: %{readOnly: true}
             },
             %{
               name: "noop",
               description: "Does nothing"
             }
           ]
  end

  test "WM-002 should report no tools when the page registers none", %{page: page, server: server} do
    Page.goto!(page, server.empty_page)
    assert WebMCP.tools!(Page.webmcp(page)) == []
  end

  test "WM-003 should call a tool", %{page: page, server: server} do
    serve(server, "/", register_script(@k_add))
    Page.goto!(page, server.prefix <> "/")

    assert WebMCP.call_tool!(Page.webmcp(page), "add", %{a: 2, b: 40}) == text_content("42")
  end

  test "WM-004 should return isError results as is", %{page: page, server: server} do
    serve(
      server,
      "/",
      register_script("""
        modelContext.registerTool({
          name: 'broken',
          description: 'Always fails',
          async execute() { return { content: [{ type: 'text', text: 'nope' }], isError: true }; },
        });
      """)
    )

    Page.goto!(page, server.prefix <> "/")

    assert WebMCP.call_tool!(Page.webmcp(page), "broken") == Map.put(text_content("nope"), "isError", true)
  end

  test "WM-005 should throw when the tool throws", %{page: page, server: server, browser_name: browser_name} do
    serve(
      server,
      "/",
      register_script("""
        modelContext.registerTool({
          name: 'throwing',
          description: 'Throws',
          async execute() { throw new Error('boom'); },
        });
      """)
    )

    Page.goto!(page, server.prefix <> "/")

    {:error, error} = WebMCP.call_tool(Page.webmcp(page), "throwing")
    # Chromium does not report the error that the tool threw.
    assert Exception.message(error) =~
             if(browser_name == "chromium", do: ~r/the invocation failed|Tool execution failed/, else: ~r/boom/)
  end

  test "WM-006 should throw for an unknown tool", %{page: page, server: server} do
    serve(server, "/", register_script(@k_add))
    Page.goto!(page, server.prefix <> "/")

    {:error, error} = WebMCP.call_tool(Page.webmcp(page), "missing")
    assert Exception.message(error) =~ ~s(No WebMCP tool named "missing")
    assert Exception.message(error) =~ "Available tools: add"
  end

  test "WM-007 should time out when the tool does not settle", %{page: page, server: server} do
    serve(
      server,
      "/",
      register_script("""
        modelContext.registerTool({
          name: 'stuck',
          description: 'Never resolves',
          execute() { return new Promise(() => {}); },
        });
      """)
    )

    Page.goto!(page, server.prefix <> "/")

    {:error, error} = WebMCP.call_tool(Page.webmcp(page), "stuck", %{}, timeout: 500)
    assert Exception.message(error) =~ "Timeout 500ms exceeded"
  end

  test "WM-008 should drop tools after navigation", %{page: page, server: server} do
    serve(server, "/", register_script(@k_add))
    Page.goto!(page, server.prefix <> "/")
    assert length(WebMCP.tools!(Page.webmcp(page))) == 1

    Page.goto!(page, server.empty_page)
    assert WebMCP.tools!(Page.webmcp(page)) == []
    {:error, error} = WebMCP.call_tool(Page.webmcp(page), "add", %{a: 1, b: 1})
    assert Exception.message(error) =~ "The frame does not register any WebMCP tools"
  end

  test "WM-009 should list a tool registered after load", %{page: page, server: server} do
    serve(server, "/", register_script(@k_add))
    Page.goto!(page, server.prefix <> "/")
    assert length(WebMCP.tools!(Page.webmcp(page))) == 1

    Page.evaluate!(page, """
    () => {
      const modelContext = document.modelContext || navigator.modelContext;
      modelContext.registerTool({ name: 'late', description: 'Registered later', async execute() {} });
    }
    """)

    tools = page |> Page.webmcp() |> WebMCP.tools!() |> Enum.sort_by(& &1.name)
    assert Enum.map(tools, & &1.name) == ["add", "late"]
  end

  test "WM-010 should list tools while a tool is running", %{page: page, server: server} do
    serve(
      server,
      "/",
      register_script(
        @k_add <>
          """
            modelContext.registerTool({
              name: 'gated',
              description: 'Resolves when released',
              execute() { return new Promise(resolve => window.release = () => resolve({ content: [{ type: 'text', text: 'released' }] })); },
            });
          """
      )
    )

    Page.goto!(page, server.prefix <> "/")

    result = Runtime.Promise.async(fn -> WebMCP.call_tool!(Page.webmcp(page), "gated") end)
    Page.wait_for_function!(page, "() => !!window.release")
    assert length(WebMCP.tools!(Page.webmcp(page))) == 2
    Page.evaluate!(page, "() => window.release()")
    assert Runtime.Promise.await(result) == text_content("released")
  end

  @tag skip: if(@browser_name != "chromium", do: "upstream skip: Only Chromium implements declarative tools")
  test "WM-011 should list declarative tools", %{page: page, server: server} do
    # test.skip(browserName !== 'chromium', 'Only Chromium implements declarative tools');
    serve(server, "/", """
      <form toolname="subscribe" tooldescription="Subscribes to the newsletter">
        <input name="email" type="email">
        <button>Subscribe</button>
      </form>
    """)

    Page.goto!(page, server.prefix <> "/")

    assert [
             %{
               name: "subscribe",
               description: "Subscribes to the newsletter",
               inputSchema: %{"type" => "object"} = input_schema
             }
           ] = WebMCP.tools!(Page.webmcp(page))

    assert input_schema["properties"] == %{"email" => %{"type" => "string"}}

    # A declarative tool waits for the user to submit the form.
    {:error, error} = WebMCP.call_tool(Page.webmcp(page), "subscribe", %{email: "me@example.com"}, timeout: 500)
    assert Exception.message(error) =~ "Timeout 500ms exceeded"
  end

  # A test's `skip: nil` would override the `@moduletag skip:`.
  @tag skip:
         if(@browser_name == "firefox",
           do: "upstream skip: Firefox does not support registering WebMCP tools in iframes yet",
           else: @webkit_skip
         )
  test "WM-012 should scope tools to their frame", %{page: page, server: server} do
    # test.skip(browserName === 'firefox', 'Firefox does not support registering WebMCP tools in iframes yet, ...');
    serve(server, "/", register_script(@k_add) <> ~s(<iframe src="/frame.html"></iframe>))

    serve(
      server,
      "/frame.html",
      register_script("""
        modelContext.registerTool({
          name: 'subscribe',
          description: 'Subscribes to the newsletter',
          async execute() { return { content: [{ type: 'text', text: 'subscribed' }] }; },
        });
      """)
    )

    Page.goto!(page, server.prefix <> "/")

    child_frame = Enum.at(Page.frames(page), 1)
    assert [%{name: "add"}] = WebMCP.tools!(Page.webmcp(page))
    assert [%{name: "subscribe"}] = WebMCP.tools!(Frame.webmcp(child_frame))
    assert WebMCP.call_tool!(Frame.webmcp(child_frame), "subscribe") == text_content("subscribed")

    {:error, error} = WebMCP.call_tool(Page.webmcp(page), "subscribe")
    assert Exception.message(error) =~ ~s(No WebMCP tool named "subscribe")
    assert Exception.message(error) =~ "Available tools: add"
  end

  defp register_echo(name, text) do
    register_script("""
      modelContext.registerTool({
        name: '#{name}',
        description: 'Echoes#{if name != "echo", do: " " <> text}',
        async execute() { return { content: [{ type: 'text', text: '#{text}' }] }; },
      });
    """)
  end

  @tag skip:
         if(@browser_name == "firefox",
           do: "upstream skip: Firefox does not support registering WebMCP tools in iframes yet",
           else: @webkit_skip
         )
  test "WM-013 should call same-name tools in their own frame", %{page: page, server: server} do
    # test.skip(browserName === 'firefox', 'Firefox does not support registering WebMCP tools in iframes yet, ...');
    serve(server, "/", register_echo("echo", "main") <> ~s(<iframe src="/frame.html"></iframe>))
    serve(server, "/frame.html", register_echo("echo", "frame"))
    Page.goto!(page, server.prefix <> "/")
    child_frame = Enum.at(Page.frames(page), 1)

    assert WebMCP.call_tool!(Page.webmcp(page), "echo") == text_content("main")
    assert WebMCP.call_tool!(Frame.webmcp(child_frame), "echo") == text_content("frame")
  end

  @tag skip:
         if(@browser_name == "firefox",
           do: "upstream skip: Firefox does not support registering WebMCP tools in iframes yet",
           else: @webkit_skip
         )
  test "WM-014 should list and call tools in cross-origin and nested frames", %{
    page: page,
    server: server
  } do
    # test.skip(browserName === 'firefox', 'Firefox does not support registering WebMCP tools in iframes yet, ...');
    serve(
      server,
      "/",
      register_echo("echo-main", "main") <>
        ~s(<iframe allow="tools" src="#{server.cross_process_prefix}/frame.html"></iframe>)
    )

    serve(server, "/frame.html", register_echo("echo-frame", "frame") <> ~s(<iframe src="/nested.html"></iframe>))
    serve(server, "/nested.html", register_echo("echo-nested", "nested"))
    Page.goto!(page, server.prefix <> "/")

    [main_frame, frame, nested] = Page.frames(page)
    assert WebMCP.tools!(Frame.webmcp(main_frame)) == [%{name: "echo-main", description: "Echoes main"}]
    assert WebMCP.tools!(Frame.webmcp(frame)) == [%{name: "echo-frame", description: "Echoes frame"}]
    assert WebMCP.tools!(Frame.webmcp(nested)) == [%{name: "echo-nested", description: "Echoes nested"}]
    assert WebMCP.call_tool!(Frame.webmcp(frame), "echo-frame") == text_content("frame")
    assert WebMCP.call_tool!(Frame.webmcp(nested), "echo-nested") == text_content("nested")
  end
end
