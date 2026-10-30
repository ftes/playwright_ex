defmodule PlaywrightEx.BrowserContextTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route

  describe "add_init_script/2" do
    test "applies script to newly created pages", %{browser_context: browser_context} do
      assert {:ok, _} =
               BrowserContext.add_init_script(browser_context.guid,
                 source: "window.__browser_context_add_init_script = 'ok';",
                 timeout: @timeout
               )

      {:ok, page} = BrowserContext.new_page(browser_context.guid, timeout: @timeout)
      {:ok, _} = Frame.goto(page.main_frame.guid, url: "about:blank", timeout: @timeout)

      assert {:ok, "ok"} = eval(page.main_frame.guid, "() => window.__browser_context_add_init_script")
    end
  end

  describe "clock_install/2" do
    test "installs the clock from a DateTime", %{browser_context: browser_context, frame: frame} do
      datetime = ~U[2024-01-02 03:04:05Z]
      expected_now = DateTime.to_unix(datetime, :millisecond)

      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      install_started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_install(browser_context.guid, time: datetime, timeout: @timeout)
      assert {:ok, installed_now} = eval(frame.guid, "() => Date.now()")
      install_elapsed = System.monotonic_time(:millisecond) - install_started_at
      assert installed_now in expected_now..(expected_now + install_elapsed + 100)

      fast_forward_started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)
      assert {:ok, advanced_now} = eval(frame.guid, "() => Date.now()")
      fast_forward_elapsed = System.monotonic_time(:millisecond) - fast_forward_started_at
      assert advanced_now in (installed_now + 60_001)..(installed_now + 60_001 + fast_forward_elapsed + 100)
    end
  end

  describe "clock_fast_forward/2" do
    test "advances Date.now after installing the clock", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, _} = BrowserContext.clock_install(browser_context.guid, timeout: @timeout)
      started_at = System.monotonic_time(:millisecond)
      assert {:ok, installed_now} = eval(frame.guid, "() => Date.now()")
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)
      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      elapsed = System.monotonic_time(:millisecond) - started_at
      assert after_now in (installed_now + 60_001)..(installed_now + 60_001 + elapsed + 100)
    end

    test "starts the clock near zero without installing first", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: 60_001, timeout: @timeout)
      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      elapsed = System.monotonic_time(:millisecond) - started_at
      assert before_now > 1_000_000
      assert after_now in 60_001..(60_001 + elapsed + 100)
    end

    test "accepts string ticks", %{browser_context: browser_context, frame: frame} do
      assert {:ok, _} = Frame.goto(frame.guid, url: "about:blank", timeout: @timeout)
      assert {:ok, before_now} = eval(frame.guid, "() => Date.now()")

      started_at = System.monotonic_time(:millisecond)
      assert {:ok, _} = BrowserContext.clock_fast_forward(browser_context.guid, ticks: "01:01", timeout: @timeout)
      assert {:ok, after_now} = eval(frame.guid, "() => Date.now()")
      elapsed = System.monotonic_time(:millisecond) - started_at
      assert before_now > 1_000_000
      assert after_now in 61_000..(61_000 + elapsed + 100)
    end
  end

  describe "storage_state/2" do
    test "restores and captures Playwright 1.63 OPFS storage snapshots", %{browser_context: browser_context} do
      origin = "https://playwright.example"

      opfs = [
        %{path: "nested", type: "directory"},
        %{path: "nested/state.txt", type: "file", base64: Base.encode64("persisted state")}
      ]

      assert {:ok, _} =
               BrowserContext.set_storage_state(browser_context.guid,
                 origins: [%{origin: origin, local_storage: [], opfs: opfs}],
                 credentials: [],
                 timeout: @timeout
               )

      assert {:ok, %{cookies: [], credentials: [], origins: [stored_origin]}} =
               BrowserContext.storage_state(browser_context.guid,
                 indexed_db: true,
                 opfs: true,
                 credentials: true,
                 timeout: @timeout
               )

      assert %{origin: ^origin, local_storage: [], indexed_db: [], opfs: ^opfs} = stored_origin
    end

    test "restores and captures virtual WebAuthn credentials", %{browser_context: browser_context} do
      credential = %{
        id: "Y3JlZGVudGlhbC1pZA",
        rp_id: "playwright.example",
        user_handle: "dXNlci1oYW5kbGU",
        private_key:
          "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgd7APaIOC9SaWeXcnLaJvUwOtVFRIJEtAn7_XRNca-iehRANCAAR_QQZB2zOOZQEFMYs7F3fzikNpyFXuoNPyyqiJrhEpRrH4DgSS0IofC3rz5UiguK1yHJ_bh-hhSHA1lEQQO57j",
        public_key:
          "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf0EGQdszjmUBBTGLOxd384pDachV7qDT8sqoia4RKUax-A4EktCKHwt68-VIoLitchyf24foYUhwNZREEDue4w",
        sign_count: 3
      }

      assert {:ok, _} =
               BrowserContext.set_storage_state(browser_context.guid,
                 credentials: [credential],
                 timeout: @timeout
               )

      assert {:ok, %{credentials: [^credential]}} =
               BrowserContext.storage_state(browser_context.guid,
                 credentials: true,
                 timeout: @timeout
               )
    end

    test "restores the Playwright 1.63 credentials field", %{browser_context: browser_context} do
      assert {:ok, _} =
               BrowserContext.set_storage_state(browser_context.guid,
                 cookies: [],
                 origins: [],
                 credentials: [],
                 timeout: @timeout
               )
    end
  end

  describe "credentials" do
    @credential %{
      id: "Y3JlZGVudGlhbC1pZA",
      rp_id: "playwright.example",
      user_handle: "dXNlci1oYW5kbGU",
      private_key:
        "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgd7APaIOC9SaWeXcnLaJvUwOtVFRIJEtAn7_XRNca-iehRANCAAR_QQZB2zOOZQEFMYs7F3fzikNpyFXuoNPyyqiJrhEpRrH4DgSS0IofC3rz5UiguK1yHJ_bh-hhSHA1lEQQO57j",
      public_key:
        "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf0EGQdszjmUBBTGLOxd384pDachV7qDT8sqoia4RKUax-A4EktCKHwt68-VIoLitchyf24foYUhwNZREEDue4w",
      sign_count: 3
    }

    @register """
    async () => {
      const credential = await navigator.credentials.create({publicKey: {
        challenge: new Uint8Array(16),
        rp: {id: "playwright.example", name: "Example"},
        user: {id: new Uint8Array(8), name: "ada", displayName: "Ada"},
        pubKeyCredParams: [{type: "public-key", alg: -7}],
        authenticatorSelection: {residentKey: "required"}
      }})
      return credential.type
    }
    """

    test "create seeds a credential that get returns and delete removes", %{browser_context: browser_context} do
      assert {:ok, %{id: id, rp_id: "playwright.example", sign_count: 0} = credential} =
               BrowserContext.credentials_create(browser_context.guid, "playwright.example", timeout: @timeout)

      assert {:ok, [^credential]} = BrowserContext.credentials_get(browser_context.guid, timeout: @timeout)
      assert {:ok, [^credential]} = BrowserContext.credentials_get(browser_context.guid, id: id, timeout: @timeout)

      assert {:ok, []} =
               BrowserContext.credentials_get(browser_context.guid, rp_id: "other.example", timeout: @timeout)

      assert {:ok, _} = BrowserContext.credentials_delete(browser_context.guid, id, timeout: @timeout)
      assert {:ok, []} = BrowserContext.credentials_get(browser_context.guid, timeout: @timeout)
    end

    test "create imports a known credential", %{browser_context: browser_context} do
      {rp_id, known} = Map.pop(@credential, :rp_id)

      assert {:ok, @credential} =
               BrowserContext.credentials_create(browser_context.guid, rp_id, Keyword.new(known) ++ [timeout: @timeout])
    end

    test "install answers the page's navigator.credentials.create", %{browser_context: browser_context} = context do
      assert {:ok, _} = BrowserContext.credentials_install(browser_context.guid, timeout: @timeout)
      serve_secure_page(context)

      assert {:ok, "public-key"} = eval(context.frame.guid, @register)

      assert {:ok, [%{rp_id: "playwright.example"}]} =
               BrowserContext.credentials_get(browser_context.guid, timeout: @timeout)
    end

    test "install answers the page's navigator.credentials.get with a seeded credential", context do
      %{browser_context: browser_context} = context
      {rp_id, known} = Map.pop(@credential, :rp_id)

      assert {:ok, _} =
               BrowserContext.credentials_create(browser_context.guid, rp_id, Keyword.new(known) ++ [timeout: @timeout])

      assert {:ok, _} = BrowserContext.credentials_install(browser_context.guid, timeout: @timeout)
      serve_secure_page(context)

      assert {:ok, "Y3JlZGVudGlhbC1pZA"} =
               eval(context.frame.guid, """
               async () => {
                 const assertion = await navigator.credentials.get({publicKey: {
                   challenge: new Uint8Array(16),
                   rpId: "playwright.example"
                 }})
                 return assertion.id
               }
               """)

      assert {:ok, [%{sign_count: 4}]} = BrowserContext.credentials_get(browser_context.guid, timeout: @timeout)
    end

    # Without an authenticator a headless ceremony never settles, so the test asks whether the
    # function was replaced instead of waiting for it.
    test "without install the page keeps the browser's own WebAuthn", context do
      serve_secure_page(context)

      assert {:ok, true} =
               eval(context.frame.guid, "() => navigator.credentials.create.toString().includes('[native code]')")
    end

    # `navigator.credentials` exists only in a secure context, so the page needs an https origin.
    defp serve_secure_page(%{page: page, frame: frame}) do
      fulfill = fn route, _request -> Route.fulfill(route, content_type: "text/html", body: "<p>ok</p>") end
      assert {:ok, _} = Page.route(page.guid, "**/*", fulfill, timeout: @timeout)
      assert {:ok, _} = Frame.goto(frame.guid, url: "https://playwright.example/", timeout: @timeout)
    end
  end

  describe "cookies" do
    test "normalizes SameSite and regex clear filters", %{browser_context: browser_context} do
      assert {:ok, _} =
               BrowserContext.add_cookies(browser_context.guid,
                 cookies: [%{name: "session", value: "1", url: "https://example.com", same_site: :lax}],
                 timeout: @timeout
               )

      assert {:ok, [%{name: "session", same_site: "Lax"}]} =
               BrowserContext.cookies(browser_context.guid,
                 urls: ["https://example.com"],
                 timeout: @timeout
               )

      assert {:ok, _} =
               BrowserContext.clear_cookies(browser_context.guid,
                 name: ~r/^sess/i,
                 timeout: @timeout
               )

      assert {:ok, []} =
               BrowserContext.cookies(browser_context.guid,
                 urls: ["https://example.com"],
                 timeout: @timeout
               )
    end
  end

  describe "dialog_closed events" do
    test "subscribes on the browser context", %{browser_context: browser_context, frame: frame} do
      :ok = PlaywrightEx.subscribe(browser_context.guid)

      on_exit(fn ->
        PlaywrightEx.unsubscribe(browser_context.guid)
      end)

      assert {:ok, _} =
               BrowserContext.update_subscription(browser_context.guid,
                 event: :dialog,
                 timeout: @timeout
               )

      assert {:ok, _} =
               BrowserContext.update_subscription(browser_context.guid,
                 event: :dialog_closed,
                 timeout: @timeout
               )

      evaluation = Task.async(fn -> eval(frame.guid, "() => alert('closed')") end)

      assert_receive {:playwright_msg,
                      %{
                        guid: context_id,
                        method: :dialog,
                        params: %{dialog: %{guid: dialog_id}}
                      }}

      assert context_id == browser_context.guid
      assert {:ok, _} = Dialog.accept(dialog_id, timeout: @timeout)

      assert_receive {:playwright_msg,
                      %{
                        guid: ^context_id,
                        method: :dialog_closed,
                        params: %{dialog: %{guid: ^dialog_id}}
                      }}

      assert {:ok, nil} = Task.await(evaluation)
    end
  end
end
