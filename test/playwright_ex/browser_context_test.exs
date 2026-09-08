defmodule PlaywrightEx.BrowserContextTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Dialog
  alias PlaywrightEx.Frame

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
          "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEf0EGQdszjmUBBTGLOxd384pDachV7qDT8sqoia4RKUax-A4EktCKHwt68-VIoLitchyf24foYUhwNZREEDue4w"
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
