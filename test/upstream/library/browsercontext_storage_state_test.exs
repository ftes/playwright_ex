defmodule PlaywrightEx.Library.BrowsercontextStorageStateTest do
  @upstream "tests/library/browsercontext-storage-state.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [attach_frame: 3]

  alias PlaywrightEx.APIRequestContext
  alias PlaywrightEx.Browser
  alias PlaywrightEx.BrowserContext
  alias PlaywrightEx.Client.ClientHelper
  alias PlaywrightEx.Credentials
  alias PlaywrightEx.Expect
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Route
  alias PlaywrightEx.TestServer

  @browser_name System.get_env("BROWSER", "chromium")

  # route.fulfill({ body: '<html></html>' }).catch(() => {})
  defp fulfill_html(page), do: Page.route!(page, "**/*", &Route.fulfill(&1, body: "<html></html>"))

  defp html(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "text/html")
    |> Plug.Conn.send_resp(200, body)
  end

  defp js(conn, body) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/javascript")
    |> Plug.Conn.send_resp(200, body)
  end

  test "ST-001 should capture local storage", %{context_factory: context_factory} do
    context = context_factory.([])
    page1 = BrowserContext.new_page!(context)
    fulfill_html(page1)
    Page.goto!(page1, "https://www.example.com")
    Page.evaluate!(page1, "() => { localStorage['name1'] = 'value1'; }")
    Page.goto!(page1, "https://www.domain.com")
    Page.evaluate!(page1, "() => { localStorage['name2'] = 'value2'; }")
    %{origins: origins} = BrowserContext.storage_state!(context)

    assert origins == [
             %{origin: "https://www.domain.com", localStorage: [%{name: "name2", value: "value2"}]},
             %{origin: "https://www.example.com", localStorage: [%{name: "name1", value: "value1"}]}
           ]
  end

  # it.fixme(channel?.startsWith('msedge'))  -- not honored: we run the bundled chromium
  test "ST-002 should set local storage", %{context_factory: context_factory} do
    context =
      context_factory.(
        storage_state: %{
          cookies: [],
          origins: [%{origin: "https://www.example.com", localStorage: [%{name: "name1", value: "value1"}]}]
        }
      )

    page = BrowserContext.new_page!(context)
    fulfill_html(page)
    Page.goto!(page, "https://www.example.com")
    local_storage = Page.evaluate!(page, "window.localStorage")
    assert local_storage == %{"name1" => "value1"}

    # Now use setStorageState to replace the storage
    BrowserContext.set_storage_state!(context, %{
      cookies: [],
      origins: [%{origin: "https://www.example.com", localStorage: [%{name: "name2", value: "value2"}]}]
    })

    assert length(BrowserContext.pages(context)) == 1
    Page.goto!(page, "https://www.example.com")
    local_storage2 = Page.evaluate!(page, "window.localStorage")
    assert local_storage2 == %{"name2" => "value2"}

    BrowserContext.close!(context)
  end

  test "ST-003 should report good error if the url is not valid", %{browser: browser} do
    # contextFactory(...).catch(e => e)
    {:error, error} =
      Browser.new_context(browser,
        storage_state: %{cookies: [], origins: [%{origin: "foo", localStorage: [%{name: "name1", value: "value1"}]}]}
      )

    assert Exception.message(error) =~ "browser.newContext: Error setting storage state:"
    assert Exception.message(error) =~ "foo"
  end

  # it.fixme(channel?.startsWith('msedge'))  -- not honored: we run the bundled chromium
  @tag :tmp_dir
  test "ST-004 should round-trip through the file", %{context_factory: context_factory, tmp_dir: tmp_dir} do
    context = context_factory.([])
    page1 = BrowserContext.new_page!(context)
    fulfill_html(page1)
    Page.goto!(page1, "https://www.example.com")

    Page.evaluate!(page1, """
    async () => {
      localStorage['name1'] = 'value1';
      document.cookie = 'username=John Doe';

      await new Promise((resolve, reject) => {
        const openRequest = indexedDB.open('db', 42);
        openRequest.onupgradeneeded = () => {
          openRequest.result.createObjectStore('store', { keyPath: 'name' });
          openRequest.result.createObjectStore('store2');
        };
        openRequest.onsuccess = () => {
          const transaction = openRequest.result.transaction(['store', 'store2'], 'readwrite');
          transaction
              .objectStore('store')
              .put({ name: 'foo', date: new Date(0), null: null });
          transaction
              .objectStore('store2')
              .put(new TextEncoder().encode('bar'), 'foo');
          transaction.addEventListener('complete', resolve);
          transaction.addEventListener('error', reject);
        };
      });

      return document.cookie;
    }
    """)

    path = Path.join(tmp_dir, "storage-state.json")
    state = BrowserContext.storage_state!(context, path: path, indexed_db: true)
    written = File.read!(path)
    # JSON.stringify(state, undefined, 2), state in protocol key order (a JS object keeps the wire's):
    assert ClientHelper.json_stringify_indented(state, 2, "BrowserContextStorageStateResult") == written

    check_context = fn context ->
      page = BrowserContext.new_page!(context)
      fulfill_html(page)
      Page.goto!(page, "https://www.example.com")
      local_storage = Page.evaluate!(page, "window.localStorage")
      assert local_storage == %{"name1" => "value1"}
      cookie = Page.evaluate!(page, "document.cookie")
      assert cookie == "username=John Doe"

      idb_values =
        Page.evaluate!(page, """
        () => new Promise((resolve, reject) => {
          const openRequest = indexedDB.open('db', 42);
          openRequest.addEventListener('success', async () => {
            const db = openRequest.result;
            const transaction = db.transaction(['store', 'store2'], 'readonly');
            const request1 = transaction.objectStore('store').get('foo');
            const request2 = transaction.objectStore('store2').get('foo');

            const [result1, result2] = await Promise.all([request1, request2].map(request => new Promise((resolve, reject) => {
              request.addEventListener('success', () => resolve(request.result));
              request.addEventListener('error', () => reject(request.error));
            })));

            resolve([result1, new TextDecoder().decode(result2)]);
          });
          openRequest.addEventListener('error', () => reject(openRequest.error));
        })
        """)

      assert idb_values == [%{"name" => "foo", "date" => ~U[1970-01-01 00:00:00.000Z], "null" => :null}, "bar"]
    end

    context2 = context_factory.(storage_state: path)
    check_context.(context2)
    BrowserContext.close!(context2)

    context3 = context_factory.([])
    BrowserContext.set_storage_state!(context3, path)
    assert BrowserContext.pages(context3) == []
    check_context.(context3)
    BrowserContext.close!(context3)
  end

  @tag :page
  @tag :tmp_dir
  @tag skip: if(@browser_name == "webkit", do: "upstream skip: OPFS is unavailable in non-persistent WebKit contexts")
  test "ST-005 should round-trip OPFS", %{
    context_factory: context_factory,
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    # annotation: issue https://github.com/microsoft/playwright/issues/41400
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    async () => {
      const root = await navigator.storage.getDirectory();
      const nested = await root.getDirectoryHandle('nested', { create: true });
      await nested.getDirectoryHandle('empty', { create: true });

      const binary = await nested.getFileHandle('data.bin', { create: true });
      const binaryWritable = await binary.createWritable();
      await binaryWritable.write(new Uint8Array([0, 1, 2, 255]));
      await binaryWritable.close();

      const text = await root.getFileHandle('hello.txt', { create: true });
      const textWritable = await text.createWritable();
      await textWritable.write('Hello, world!');
      await textWritable.close();
    }
    """)

    assert BrowserContext.storage_state!(Page.context(page)) == %{cookies: [], origins: []}

    path = Path.join(tmp_dir, "storage-state.json")
    storage_state = BrowserContext.storage_state!(Page.context(page), path: path, opfs: true)

    assert storage_state.origins == [
             %{
               origin: server.prefix,
               localStorage: [],
               opfs: [
                 %{path: "hello.txt", type: "file", base64: "SGVsbG8sIHdvcmxkIQ=="},
                 %{path: "nested", type: "directory"},
                 %{path: "nested/data.bin", type: "file", base64: "AAEC/w=="},
                 %{path: "nested/empty", type: "directory"}
               ]
             }
           ]

    assert path |> File.read!() |> JSON.decode!() == string_keys(storage_state)
    assert APIRequestContext.storage_state!(BrowserContext.request(Page.context(page)), opfs: true) == storage_state

    check_context = fn context ->
      assert BrowserContext.storage_state!(context, opfs: true) == storage_state
      check_page = BrowserContext.new_page!(context)
      Page.goto!(check_page, server.empty_page)

      assert Page.evaluate!(check_page, """
             async () => {
               const root = await navigator.storage.getDirectory();
               const hello = await (await root.getFileHandle('hello.txt')).getFile();
               const nested = await root.getDirectoryHandle('nested');
               const data = await (await nested.getFileHandle('data.bin')).getFile();
               const empty = await nested.getDirectoryHandle('empty');
               const emptyEntries = [];
               for await (const name of empty.keys())
                 emptyEntries.push(name);
               return {
                 text: await hello.text(),
                 bytes: [...new Uint8Array(await data.arrayBuffer())],
                 empty: emptyEntries,
               };
             }
             """) == %{"text" => "Hello, world!", "bytes" => [0, 1, 2, 255], "empty" => []}
    end

    context2 = context_factory.(storage_state: path)
    check_context.(context2)
    BrowserContext.close!(context2)

    context3 = context_factory.([])
    page3 = BrowserContext.new_page!(context3)
    Page.goto!(page3, server.empty_page)

    Page.evaluate!(page3, """
    async () => {
      const root = await navigator.storage.getDirectory();
      await root.getFileHandle('stale.txt', { create: true });
    }
    """)

    BrowserContext.set_storage_state!(context3, storage_state)
    check_context.(context3)
    BrowserContext.close!(context3)
  end

  @tag :page
  test "ST-006 should capture cookies", %{
    server: server,
    context: context,
    page: page,
    context_factory: context_factory
  } do
    TestServer.set_route(server, "/setcookie.html", fn conn ->
      conn
      |> Plug.Conn.prepend_resp_headers([{"set-cookie", "a=b"}, {"set-cookie", "empty="}])
      |> Plug.Conn.send_resp(200, "")
    end)

    Page.goto!(page, server.prefix <> "/setcookie.html")

    assert Page.evaluate!(page, """
           () => {
             const cookies = document.cookie.split(';');
             return cookies.map(cookie => cookie.trim()).sort();
           }
           """) == ["a=b", "empty="]

    storage_state = BrowserContext.storage_state!(context)
    # new Set(cookies) toEqual new Set([objectContaining(...), ...])
    assert [_, _] = storage_state.cookies
    assert Enum.any?(storage_state.cookies, &match?(%{name: "a", value: "b"}, &1))
    assert Enum.any?(storage_state.cookies, &match?(%{name: "empty", value: ""}, &1))
    context2 = context_factory.(storage_state: storage_state)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)

    assert Page.evaluate!(page2, """
           () => {
             const cookies = document.cookie.split(';');
             return cookies.map(cookie => cookie.trim()).sort();
           }
           """) == ["a=b", "empty="]
  end

  test "ST-007 should not emit events about internal page", %{context_factory: context_factory} do
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    Page.route!(page, "**/*", &Route.fulfill(&1, body: "<html></html>"))
    Page.goto!(page, "https://www.example.com")
    Page.evaluate!(page, "() => localStorage['name1'] = 'value1'")
    Page.goto!(page, "https://www.domain.com")
    Page.evaluate!(page, "() => localStorage['name2'] = 'value2'")

    me = self()

    for event <- [:page, :request, :request_failed, :request_finished, :response],
        do: BrowserContext.on(context, event, &send(me, {:event, &1}))

    BrowserContext.storage_state!(context)
    refute_received {:event, _}
  end

  test "ST-008 should not restore localStorage twice", %{context_factory: context_factory} do
    context =
      context_factory.(
        storage_state: %{
          cookies: [],
          origins: [%{origin: "https://www.example.com", localStorage: [%{name: "name1", value: "value1"}]}]
        }
      )

    page = BrowserContext.new_page!(context)
    fulfill_html(page)
    Page.goto!(page, "https://www.example.com")
    local_storage1 = Page.evaluate!(page, "window.localStorage")
    assert local_storage1 == %{"name1" => "value1"}

    Page.evaluate!(page, "() => window.localStorage['name1'] = 'value2'")

    Page.goto!(page, "https://www.example.com")
    local_storage2 = Page.evaluate!(page, "window.localStorage")
    assert local_storage2 == %{"name1" => "value2"}

    BrowserContext.close!(context)
  end

  @tag :tmp_dir
  test "ST-009 should handle missing file", %{browser: browser, tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "does-not-exist.json")
    {:error, error} = Browser.new_context(browser, storage_state: file)
    # deviation: Elixir's File error text, not Node's ENOENT.
    assert error.message =~ "Error reading storage state from #{file}:\ncould not read file"
    assert %File.Error{reason: :enoent, path: ^file} = error.cause
  end

  @tag :tmp_dir
  test "ST-010 should handle malformed file", %{browser: browser, tmp_dir: tmp_dir} do
    file = Path.join(tmp_dir, "state.json")
    File.write!(file, "not-json")
    {:error, error} = Browser.new_context(browser, storage_state: file)
    # Node's JSON.parse error text (`Unexpected token 'o', "not-json" is not valid JSON`)  -- Elixir's JSON error text
    assert Exception.message(error) =~
             "Error reading storage state from #{file}:\ninvalid byte 111 at position (byte offset) 1"
  end

  @tag :page
  test "ST-011 should serialize storageState with lone surrogates", %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright-dotnet/issues/2819
    Page.goto!(page, server.empty_page)
    Page.evaluate!(page, "() => window.localStorage.setItem('foo', String.fromCharCode(55934))")
    storage_state = BrowserContext.storage_state!(context)

    # String.fromCharCode(55934): an Elixir (UTF-8) string cannot hold a lone surrogate, the page's own value decodes the same
    assert hd(hd(storage_state.origins).localStorage).value == Page.evaluate!(page, "String.fromCharCode(55934)")
  end

  # it.skip(isAndroid), it.skip(isElectron && ...)  -- not honored: no Android/Electron
  @tag :page
  test "ST-012 should work when service worker is intefering", %{page: page, context: context, server: server} do
    TestServer.set_route(server, "/", fn conn ->
      html(conn, """
        <script>
          console.log('from page');
          window.localStorage.foo = 'bar';
          window.registrationPromise = navigator.serviceWorker.register('sw.js');
          window.activationPromise = new Promise(resolve => navigator.serviceWorker.oncontrollerchange = resolve);
        </script>
      """)
    end)

    TestServer.set_route(server, "/sw.js", fn conn ->
      js(conn, """
        const kHtmlPage = `
          <script>
            console.log('from sw page');
            let counter = window.localStorage.counter || 0;
            ++counter;
            window.localStorage.counter = counter;
            setTimeout(() => {
              window.location.href = counter + '.html';
            }, 0);
          </script>
        `;

        console.log('from sw 1');
        self.addEventListener('fetch', event => {
          console.log('fetching ' + event.request.url);
          const blob = new Blob([kHtmlPage], { type: 'text/html' });
          const response = new Response(blob, { status: 200 , statusText: 'OK' });
          event.respondWith(response);
        });

        self.addEventListener('activate', event => {
          console.log('from sw 2');
          event.waitUntil(clients.claim());
        });
      """)
    end)

    Page.goto!(page, server.prefix)
    Page.evaluate!(page, "() => window['activationPromise']")

    storage_state = BrowserContext.storage_state!(context)
    assert hd(hd(storage_state.origins).localStorage) == %{name: "foo", value: "bar"}
  end

  # it.skip(isAndroid), it.skip(isElectron && ...)  -- not honored: no Android/Electron
  @tag :page
  test "ST-013 should work when service worker is intefering and the origin is not open",
       %{page: page, context: context, server: server} do
    # issue: https://github.com/microsoft/playwright/issues/42656
    TestServer.set_route(server, "/", fn conn ->
      html(conn, """
        <script>
          window.localStorage.foo = 'bar';
          window.registrationPromise = navigator.serviceWorker.register('sw.js');
          window.activationPromise = new Promise(resolve => navigator.serviceWorker.oncontrollerchange = resolve);
        </script>
      """)
    end)

    TestServer.set_route(server, "/sw.js", fn conn ->
      js(conn, """
        const kHtmlPage = `
          <script>
            window.localStorage.fromServiceWorker = 'yes';
            window.location.href = 'redirected.html';
          </script>
        `;

        self.addEventListener('fetch', event => {
          if (new URL(event.request.url).pathname !== '/')
            return;
          const blob = new Blob([kHtmlPage], { type: 'text/html' });
          event.respondWith(new Response(blob, { status: 200, statusText: 'OK' }));
        });

        self.addEventListener('activate', event => {
          event.waitUntil(clients.claim());
        });
      """)
    end)

    TestServer.set_route(server, "/redirected.html", &html(&1, "<html></html>"))

    Page.goto!(page, server.prefix)
    Page.evaluate!(page, "() => window['activationPromise']")
    Page.goto!(page, "about:blank")

    storage_state = BrowserContext.storage_state!(context)
    assert hd(storage_state.origins).localStorage == [%{name: "foo", value: "bar"}]
  end

  test "ST-014 should set local storage in third-party context", %{context_factory: context_factory, server: server} do
    context =
      context_factory.(
        storage_state: %{
          cookies: [],
          origins: [%{origin: server.cross_process_prefix, localStorage: [%{name: "name1", value: "value1"}]}]
        }
      )

    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)
    frame = attach_frame(page, "frame1", server.cross_process_prefix <> "/empty.html")

    local_storage = Frame.evaluate!(frame, "window.localStorage")
    assert local_storage == %{"name1" => "value1"}
    BrowserContext.close!(context)
  end

  @tag :page
  test "ST-015 should roundtrip local storage in third-party context",
       %{page: page, context_factory: context_factory, server: server} do
    Page.goto!(page, server.empty_page)
    frame = attach_frame(page, "frame1", server.cross_process_prefix <> "/empty.html")
    Frame.evaluate!(frame, "() => window.localStorage.setItem('name1', 'value1')")
    storage_state = BrowserContext.storage_state!(Page.context(page))

    context2 = context_factory.(storage_state: storage_state)
    page2 = BrowserContext.new_page!(context2)
    Page.goto!(page2, server.empty_page)
    frame2 = attach_frame(page2, "frame1", server.cross_process_prefix <> "/empty.html")

    local_storage = Frame.evaluate!(frame2, "window.localStorage")
    assert local_storage == %{"name1" => "value1"}
    BrowserContext.close!(context2)
  end

  @tag :page
  test "ST-016 should support IndexedDB", %{page: page, server: server, context_factory: context_factory} do
    Page.goto!(page, server.prefix <> "/to-do-notifications/index.html")

    Expect.to_match_aria_snapshot!(Page.locator(page, "#notifications"), """
    - list:
      - listitem: Database initialised.
    """)

    Locator.fill!(Page.get_by_label(page, "Task title"), "Pet the cat")
    Locator.fill!(Page.get_by_label(page, "Hours"), "1")
    Locator.fill!(Page.get_by_label(page, "Mins"), "1")
    Locator.click!(Page.get_by_text(page, "Add Task"))

    Expect.to_match_aria_snapshot!(Page.locator(page, "#notifications"), """
    - list:
      - listitem: "Transaction completed: database modification finished."
    """)

    storage_state = BrowserContext.storage_state!(Page.context(page), indexed_db: true)

    index = fn name -> %{name: name, keyPath: name, multiEntry: false, unique: false} end

    assert storage_state.origins == [
             %{
               origin: server.prefix,
               localStorage: [],
               indexedDB: [
                 %{
                   name: "toDoList",
                   version: 4,
                   stores: [
                     %{
                       name: "toDoList",
                       autoIncrement: false,
                       keyPath: "taskTitle",
                       records: [
                         %{
                           # `valueEncoded` is protocol `json`: string keys
                           valueEncoded: %{
                             "id" => 1,
                             "o" => [
                               %{"k" => "taskTitle", "v" => "Pet the cat"},
                               %{"k" => "hours", "v" => "1"},
                               %{"k" => "minutes", "v" => "1"},
                               %{"k" => "day", "v" => "01"},
                               %{"k" => "month", "v" => "January"},
                               %{"k" => "year", "v" => "2025"},
                               %{"k" => "notified", "v" => "no"},
                               %{"k" => "binaryTitle", "v" => %{"ab" => %{"b" => "UGV0IHRoZSBjYXQ="}}}
                             ]
                           }
                         }
                       ],
                       indexes: Enum.map(["day", "hours", "minutes", "month", "notified", "year"], index)
                     }
                   ]
                 }
               ]
             }
           ]

    context = context_factory.(storage_state: storage_state)
    assert BrowserContext.storage_state!(context, indexed_db: true) == storage_state

    recreated_page = BrowserContext.new_page!(context)
    Page.goto!(recreated_page, server.prefix <> "/to-do-notifications/index.html")

    Expect.to_match_aria_snapshot!(Page.locator(recreated_page, "#task-list"), """
    - list:
      - listitem:
        - text: /Pet the cat \\[Pet the cat\\]/
    """)

    assert BrowserContext.storage_state!(context) == %{cookies: [], origins: []}
  end

  for restore <- ["newContext", "setStorageState"] do
    @restore restore
    @tag :page
    @tag :tmp_dir
    test "should roundtrip IndexedDB Map and Set with #{restore}",
         %{page: page, server: server, context_factory: context_factory, tmp_dir: tmp_dir} do
      # annotation: issue https://github.com/microsoft/playwright/issues/42703
      Page.goto!(page, server.empty_page)

      Page.evaluate!(page, """
      () => new Promise((resolve, reject) => {
        const request = indexedDB.open('collections', 1);
        request.onupgradeneeded = () => request.result.createObjectStore('store');
        request.onerror = () => reject(request.error);
        request.onsuccess = () => {
          const db = request.result;
          const transaction = db.transaction('store', 'readwrite');
          const store = transaction.objectStore('store');
          store.put(new Map([['mk', 'mv']]), 'map');
          store.put(new Set([1, 2]), 'set');
          transaction.oncomplete = () => {
            db.close();
            resolve();
          };
          transaction.onerror = () => reject(transaction.error);
        };
      })
      """)

      path = Path.join(tmp_dir, "storage-state.json")
      storage_state = BrowserContext.storage_state!(Page.context(page), indexed_db: true, path: path)
      context = context_factory.(if(@restore == "newContext", do: [storage_state: path], else: []))
      if @restore == "setStorageState", do: BrowserContext.set_storage_state!(context, storage_state)
      assert BrowserContext.storage_state!(context, indexed_db: true) == storage_state

      restored_page = BrowserContext.new_page!(context)
      Page.goto!(restored_page, server.empty_page)

      values =
        Page.evaluate!(restored_page, """
        async () => {
          const db = await new Promise((resolve, reject) => {
            const request = indexedDB.open('collections', 1);
            request.onerror = () => reject(request.error);
            request.onsuccess = () => resolve(request.result);
          });
          const transaction = db.transaction('store', 'readonly');
          const store = transaction.objectStore('store');
          transaction.oncomplete = () => db.close();
          const [map, set] = await Promise.all(['map', 'set'].map(key => new Promise((resolve, reject) => {
            const request = store.get(key);
            request.onsuccess = () => resolve(request.result);
            request.onerror = () => reject(request.error);
          })));
          return {
            isMap: map instanceof Map,
            map: [...map],
            isSet: set instanceof Set,
            set: [...set],
          };
        }
        """)

      assert values == %{"isMap" => true, "map" => [["mk", "mv"]], "isSet" => true, "set" => [1, 2]}
    end
  end

  @tag :page
  test "ST-018 should support empty indexedDB", %{page: page, server: server, context_factory: context_factory} do
    # annotation: issue https://github.com/microsoft/playwright/issues/35760
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    () => new Promise(resolve => {
      const openRequest = indexedDB.open('unused-db');
      openRequest.onsuccess = () => resolve();
      openRequest.onerror = () => resolve();
    })
    """)

    storage_state = BrowserContext.storage_state!(Page.context(page), indexed_db: true)

    assert storage_state.origins == [
             %{origin: server.prefix, localStorage: [], indexedDB: [%{name: "unused-db", version: 1, stores: []}]}
           ]

    context = context_factory.(storage_state: storage_state)
    assert BrowserContext.storage_state!(context, indexed_db: true) == storage_state
  end

  test "ST-019 should not leave IndexedDB connections open", %{context_factory: context_factory, server: server} do
    # annotation: issue https://github.com/microsoft/playwright/issues/42258
    context = context_factory.([])
    page = BrowserContext.new_page!(context)
    Page.goto!(page, server.empty_page)

    Page.evaluate!(page, """
    async () => {
      const openRequest = indexedDB.open('db', 1);
      openRequest.onupgradeneeded = () => openRequest.result.createObjectStore('store');
      await new Promise((resolve, reject) => {
        openRequest.onsuccess = () => {
          const db = openRequest.result;
          const transaction = db.transaction('store', 'readwrite');
          transaction.objectStore('store').put('value', 'key');
          transaction.oncomplete = () => {
            db.close();
            resolve();
          };
          transaction.onerror = () => reject(transaction.error);
        };
        openRequest.onerror = () => reject(openRequest.error);
      });
    }
    """)

    state = BrowserContext.storage_state!(context, indexed_db: true)

    Page.evaluate!(page, """
    () => new Promise((resolve, reject) => {
      const request = indexedDB.deleteDatabase('db');
      request.onsuccess = () => resolve();
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error('deleteDatabase was blocked'));
    })
    """)

    BrowserContext.set_storage_state!(context, state)
    assert BrowserContext.storage_state!(context, indexed_db: true) == state
  end

  test "ST-020 should round-trip WebAuthn credentials with storageState", %{
    context_factory: context_factory,
    server: server
  } do
    context = context_factory.([])
    credential = Credentials.create!(BrowserContext.credentials(context), server.hostname)

    # Credentials are opt-in, omitted by default.
    assert BrowserContext.storage_state!(context) == %{cookies: [], origins: []}

    storage_state = BrowserContext.storage_state!(context, credentials: true)
    assert storage_state == %{cookies: [], origins: [], credentials: [credential]}

    # A fresh context seeded from the storage state holds the same credential and round-trips equal.
    context2 = context_factory.(storage_state: storage_state)
    assert Credentials.get!(BrowserContext.credentials(context2)) == [credential]
    assert BrowserContext.storage_state!(context2, credentials: true) == storage_state
  end

  test "ST-021 setStorageState should replace credentials", %{context_factory: context_factory} do
    ctx_a = context_factory.([])
    cred_a = Credentials.create!(BrowserContext.credentials(ctx_a), "a.example.com")
    state_a = BrowserContext.storage_state!(ctx_a, credentials: true)

    ctx_b = context_factory.([])
    cred_b = Credentials.create!(BrowserContext.credentials(ctx_b), "b.example.com")
    state_b = BrowserContext.storage_state!(ctx_b, credentials: true)

    context = context_factory.(storage_state: state_a)
    assert Credentials.get!(BrowserContext.credentials(context)) == [cred_a]

    # Replacing the storage state swaps in the new credentials.
    BrowserContext.set_storage_state!(context, state_b)
    assert Credentials.get!(BrowserContext.credentials(context)) == [cred_b]

    # A storage state without credentials clears them.
    BrowserContext.set_storage_state!(context, %{cookies: [], origins: []})
    assert Credentials.get!(BrowserContext.credentials(context)) == []

    # Credentials can be installed again afterwards.
    BrowserContext.set_storage_state!(context, state_a)
    assert Credentials.get!(BrowserContext.credentials(context)) == [cred_a]
  end

  @tag :tmp_dir
  test "ST-022 setStorageState should handle missing file", %{context_factory: context_factory, tmp_dir: tmp_dir} do
    context = context_factory.([])
    file = Path.join(tmp_dir, "does-not-exist.json")
    {:error, error} = BrowserContext.set_storage_state(context, file)
    assert error.message =~ "Error reading storage state from #{file}"
  end

  # The JSON file has string keys, the returned state atom keys.
  defp string_keys(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), string_keys(v)} end)
  defp string_keys(list) when is_list(list), do: Enum.map(list, &string_keys/1)
  defp string_keys(value), do: value
end
