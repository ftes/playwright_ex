defmodule PlaywrightEx.Page.PageFilechooserTest do
  @upstream "tests/page/page-filechooser.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [attach_frame: 3, assert_truthy: 1]

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.ConsoleMessage
  alias PlaywrightEx.FileChooser
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
  alias PlaywrightEx.Route
  alias PlaywrightEx.Runtime
  alias PlaywrightEx.TestServer
  alias PlaywrightEx.TimeoutError

  @moduletag :page

  @read_selected_file """
  async picker => {
    picker.click();
    await new Promise(x => picker.oninput = x);
    const reader = new FileReader();
    const promise = new Promise(fulfill => reader.onload = fulfill);
    reader.readAsText(picker.files[0]);
    return promise.then(() => reader.result);
  }
  """

  @pick_files_length """
  async picker => {
    picker.click();
    await new Promise(x => picker.oninput = x);
    return picker.files.length;
  }
  """

  # `page.waitForEvent('filechooser').then(fileChooser => fileChooser.setFiles(files))`
  defp set_files_on_chooser(page, files) do
    promise = Page.wait_for_event(page, :file_chooser)
    Runtime.Promise.async(fn -> promise |> Promise.await!() |> FileChooser.set_files!(files) end)
  end

  # A listener that refers to itself (`const listener = chooser => { page.off(..., listener); ... }`):
  # closures over the same code and environment compare equal.
  defp self_removing_listener(page, remove, test) do
    make = fn make ->
      fn chooser ->
        remove.(page, :file_chooser, make.(make))
        send(test, {:chooser, chooser})
      end
    end

    make.(make)
  end

  @tag :tmp_dir
  # test.slow()
  @tag timeout: @slow_timeout
  test "FC-001 should upload multiple large files", %{page: page, server: server, tmp_dir: tmp_dir} do
    files_count = 10
    Page.goto!(page, server.prefix <> "/input/fileupload-multi.html")
    upload_file = Path.join(tmp_dir, "50MB_1.zip")
    str = String.duplicate("A", 1024)
    # 49 is close to the actual limit
    File.open!(upload_file, [:write, :raw, :binary], fn file -> for _ <- 1..(49 * 1024), do: IO.binwrite(file, str) end)
    input = Page.locator(page, ~s|input[type="file"]|)

    upload_files =
      [upload_file] ++
        for i <- 2..files_count do
          dst_file = Path.join(tmp_dir, "50MB_#{i}.zip")
          File.cp!(upload_file, dst_file)
          dst_file
        end

    file_chooser_promise = Page.wait_for_event(page, :file_chooser)
    Locator.click!(input)
    file_chooser = Promise.await!(file_chooser_promise)
    FileChooser.set_files!(file_chooser, upload_files)
    files_len = Page.evaluate!(page, ~s|document.getElementsByTagName("input")[0].files.length|)
    assert FileChooser.is_multiple(file_chooser) == true
    assert files_len == files_count
    Enum.each(upload_files, &File.rm!/1)
  end

  test "FC-002 should emit event once", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    test = self()
    Page.once(page, :file_chooser, &send(test, {:chooser, &1}))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "FC-003 should emit event via prepend", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    test = self()
    Page.prepend_listener(page, :file_chooser, &send(test, {:chooser, &1}))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "FC-004 should emit event for iframe", %{page: page, server: server} do
    frame = attach_frame(page, "frame1", server.empty_page)
    Frame.set_content!(frame, "<input type=file>")
    test = self()
    Page.once(page, :file_chooser, &send(test, {:chooser, &1}))
    Frame.click!(frame, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "FC-005 should emit event on/off", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    Page.on(page, :file_chooser, self_removing_listener(page, &Page.off/3, self()))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "FC-006 should emit event addListener/removeListener", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    Page.add_listener(page, :file_chooser, self_removing_listener(page, &Page.remove_listener/3, self()))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "FC-007 should work when file input is attached to DOM", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    chooser = Promise.await!(promise)
    assert chooser
  end

  test "FC-008 should work when file input is not attached to DOM", %{page: page, asset: asset} do
    set_files = set_files_on_chooser(page, asset.("file-to-upload.txt"))

    content =
      Page.evaluate!(page, """
      async () => {
        const el = document.createElement('input');
        el.type = 'file';
        el.click();
        await new Promise(x => el.oninput = x);
        const reader = new FileReader();
        const promise = new Promise(fulfill => reader.onload = fulfill);
        reader.readAsText(el.files[0]);
        return promise.then(() => reader.result);
      }
      """)

    Runtime.Promise.await(set_files)
    assert content == "contents of the file"
  end

  test "FC-009 should not throw when filechooser belongs to iframe", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    frame = page |> Page.main_frame() |> Frame.child_frames() |> hd()

    Frame.set_content!(frame, """
    <div>Click me</div>
    <script>
      document.querySelector('div').addEventListener('click', () => {
        const input = document.createElement('input');
        input.type = 'file';
        input.click();
        window.parent.__done = true;
      });
    </script>
    """)

    promise = Page.wait_for_event(page, :file_chooser)
    Frame.click!(frame, "div")
    Promise.await!(promise)
    Page.wait_for_function!(page, "() => window.__done")
  end

  test "FC-010 should not throw when frame is detached immediately", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/frames/one-frame.html")
    frame = page |> Page.main_frame() |> Frame.child_frames() |> hd()

    Frame.set_content!(frame, """
    <div>Click me</div>
    <script>
      document.querySelector('div').addEventListener('click', () => {
        const input = document.createElement('input');
        input.type = 'file';
        input.click();
        window.parent.__done = true;
        const iframe = window.parent.document.querySelector('iframe');
        iframe.remove();
      });
    </script>
    """)

    # To ensure we handle file choosers.
    Page.on(page, :file_chooser, fn _ -> nil end)
    Frame.click!(frame, "div")
    Page.wait_for_function!(page, "() => window.__done")
  end

  test "FC-011 should respect timeout", %{page: page} do
    {:error, error} = page |> Page.wait_for_event(:file_chooser, timeout: 1) |> Promise.await()
    assert %TimeoutError{} = error
  end

  test "FC-012 should respect default timeout when there is no custom timeout", %{page: page} do
    Page.set_default_timeout(page, 1)
    {:error, error} = page |> Page.wait_for_event(:file_chooser) |> Promise.await()
    assert %TimeoutError{} = error
  end

  test "FC-013 should prioritize exact timeout over default timeout", %{page: page} do
    Page.set_default_timeout(page, 0)
    {:error, error} = page |> Page.wait_for_event(:file_chooser, timeout: 1) |> Promise.await()
    assert %TimeoutError{} = error
  end

  test "FC-014 should work with no timeout", %{page: page} do
    promise = Page.wait_for_event(page, :file_chooser, timeout: 0)

    Page.evaluate!(page, """
    () => window.builtins.setTimeout(() => {
      const el = document.createElement('input');
      el.type = 'file';
      el.click();
    }, 50)
    """)

    chooser = Promise.await!(promise)
    assert chooser
  end

  test "FC-015 should abort with signal", %{page: page} do
    controller = AbortController.new()
    promise = Page.wait_for_event(page, :file_chooser, signal: AbortController.signal(controller))
    AbortController.abort(controller, "Aborted by user")
    {:error, error} = Promise.await(promise)
    assert error.name == "AbortError"
    assert error.cause == "Aborted by user"
  end

  test "FC-016 should return the same file chooser when there are many watchdogs simultaneously", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    promise1 = Page.wait_for_event(page, :file_chooser)
    promise2 = Page.wait_for_event(page, :file_chooser)
    Page.eval_on_selector!(page, "input", "input => input.click()")
    file_chooser1 = Promise.await!(promise1)
    file_chooser2 = Promise.await!(promise2)
    assert file_chooser1 == file_chooser2
  end

  test "FC-017 should accept single file", %{page: page, asset: asset} do
    Page.set_content!(page, "<input type=file oninput='javascript:console.timeStamp()'>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    file_chooser = Promise.await!(promise)
    assert FileChooser.page(file_chooser) == page
    assert FileChooser.element(file_chooser)
    FileChooser.set_files!(file_chooser, asset.("file-to-upload.txt"))
    assert Page.eval_on_selector!(page, "input", "input => input.files.length") == 1
    assert Page.eval_on_selector!(page, "input", "input => input.files[0].name") == "file-to-upload.txt"
  end

  # @see https://github.com/microsoft/playwright/issues/4704
  test "FC-018 should not trim big uploaded files", %{page: page, server: server} do
    test = self()

    TestServer.set_route(server, "/upload", fn conn ->
      send(test, {:files, parse_multipart(conn)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.goto!(page, server.empty_page)

    data_size = Integer.pow(2, 20)
    request = TestServer.wait_for_request(server, "/upload")

    Page.evaluate!(
      page,
      """
      async size => {
        const body = new FormData();
        body.set('file', new Blob([new Uint8Array(size)]));
        await fetch('/upload', { method: 'POST', body });
      }
      """,
      data_size
    )

    Task.await(request, :infinity)
    assert_receive {:files, %{"file" => file}}
    assert file.size == data_size
  end

  test "FC-019 should be able to read selected file", %{page: page, asset: asset} do
    Page.set_content!(page, "<input type=file>")
    set_files = set_files_on_chooser(page, asset.("file-to-upload.txt"))
    content = Page.eval_on_selector!(page, "input", @read_selected_file)
    Runtime.Promise.await(set_files)
    assert content == "contents of the file"
  end

  test "FC-020 should be able to reset selected files with empty file list", %{page: page, asset: asset} do
    Page.set_content!(page, "<input type=file>")
    set_files1 = set_files_on_chooser(page, asset.("file-to-upload.txt"))
    file_length1 = Page.eval_on_selector!(page, "input", @pick_files_length)
    Runtime.Promise.await(set_files1)
    assert file_length1 == 1
    set_files2 = set_files_on_chooser(page, [])
    file_length2 = Page.eval_on_selector!(page, "input", @pick_files_length)
    Runtime.Promise.await(set_files2)
    assert file_length2 == 0
  end

  test "FC-021 should work for single file pick", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    file_chooser = Promise.await!(promise)
    assert FileChooser.is_multiple(file_chooser) == false
  end

  test "FC-022 should work for \"multiple\"", %{page: page} do
    Page.set_content!(page, "<input multiple type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    file_chooser = Promise.await!(promise)
    assert FileChooser.is_multiple(file_chooser) == true
  end

  test "FC-023 should work for \"webkitdirectory\"", %{page: page} do
    Page.set_content!(page, "<input multiple webkitdirectory type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    file_chooser = Promise.await!(promise)
    assert FileChooser.is_multiple(file_chooser) == true
  end

  # https://github.com/microsoft/playwright/issues/11375
  # test.skip(browserName === 'chromium' && browserMajorVersion < 99): the pinned browsers are newer.
  test "FC-024 should emit event after navigation", %{page: page, server: server} do
    test = self()
    Page.on(page, :file_chooser, fn _ -> send(test, {:log, "filechooser"}) end)
    Page.goto!(page, server.prefix <> "/empty.html")
    Page.set_content!(page, "<input type=file>")
    promise1 = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    Promise.await!(promise1)
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    Page.set_content!(page, "<input type=file>")
    promise2 = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    Promise.await!(promise2)
    assert logs() == ["filechooser", "filechooser"]
  end

  # test.skip(isElectron && browserMajorVersion <= 98): no Electron.
  test "FC-025 should trigger listener added before navigation", %{page: page, server: server} do
    # Add listener before cross process navigation.
    test = self()
    Page.once(page, :file_chooser, &send(test, {:chooser, &1}))
    Page.goto!(page, server.prefix <> "/empty.html")
    Page.goto!(page, server.cross_process_prefix <> "/empty.html")
    Page.set_content!(page, "<input type=file>")
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  describe "user activation" do
    # Each test navigates to a fresh document, because transient activation
    # (including the one granted by page.evaluate in all browsers) sticks to
    # the document for several seconds.
    @activation_html """
      <button id="once">once</button>
      <button id="twice">twice</button>
      <input type=file>
      <script>
        const input = document.querySelector('input');
        document.querySelector('#once').addEventListener('click', () => input.click());
        document.querySelector('#twice').addEventListener('click', () => { input.click(); input.click(); });
        window.showPicker = () => {
          try {
            input.showPicker();
            return 'ok';
          } catch (e) {
            return e.name;
          }
        };
        if (location.search === '?click')
          setTimeout(() => input.click(), 0);
        if (location.search === '?showPicker')
          setTimeout(() => console.log('showPicker:' + window.showPicker()), 0);
      </script>
    """

    setup %{page: page, server: server} do
      Page.route!(page, server.prefix <> "/activation.html*", fn route ->
        Route.fulfill(route, content_type: "text/html", body: @activation_html)
      end)

      :ok
    end

    @tag skip:
           if(@browser_name == "webkit",
             do: "upstream fixme: WebKit opens the file chooser from input.click() without user activation"
           )
    test "FC-026 should not open file chooser without user activation", %{page: page, server: server} do
      # test.skip(process.env.PW_CLOCK === 'frozen');  -- not ported: no frozen-clock mode
      test = self()
      Page.on(page, :file_chooser, fn _ -> send(test, :chooser) end)

      Page.goto!(page, server.prefix <> "/activation.html?click")
      Page.wait_for_timeout!(page, 500)
      assert choosers() == 0

      # Do not poll with waitForFunction: each poll evaluates in the page with a user gesture,
      # which grants transient user activation and would let showPicker() succeed.
      result = Page.wait_for_event(page, :console, &String.starts_with?(ConsoleMessage.text(&1), "showPicker:"))
      Page.goto!(page, server.prefix <> "/activation.html?showPicker")
      assert ConsoleMessage.text(Promise.await!(result)) == "showPicker:NotAllowedError"
      assert choosers() == 0
    end

    test "FC-027 should open file chooser with user activation", %{page: page, server: server} do
      Page.goto!(page, server.prefix <> "/activation.html")
      chooser = Page.expect_event!(page, :file_chooser, fn -> Page.click!(page, "#once") end)
      assert_truthy(chooser)

      # page.evaluate grants transient user activation in all browsers.
      Page.goto!(page, server.prefix <> "/activation.html")

      chooser2 =
        Page.expect_event!(page, :file_chooser, fn ->
          Page.evaluate!(page, "() => document.querySelector('input').click()")
        end)

      assert_truthy(chooser2)
      Page.goto!(page, server.prefix <> "/activation.html")
      assert Page.evaluate!(page, "() => window.showPicker()") == "ok"
    end

    @tag skip:
           if(@browser_name == "webkit",
             do: "upstream fixme: WebKit does not consume user activation when opening the file chooser"
           )
    test "FC-028 should consume user activation when opening file chooser", %{page: page, server: server} do
      # test.fixme(isElectron || isAndroid, ...)  -- neither applies here
      test = self()
      Page.on(page, :file_chooser, fn _ -> send(test, :chooser) end)
      Page.goto!(page, server.prefix <> "/activation.html")
      Page.click!(page, "#twice")
      Page.wait_for_timeout!(page, 500)
      assert choosers() == 1
    end
  end

  # `let choosers = 0; page.on('filechooser', () => choosers++)`: the listener sends to the test process.
  defp choosers(count \\ 0) do
    receive do
      :chooser -> choosers(count + 1)
    after
      0 -> count
    end
  end

  # `const logs = []; ... logs.push(x)`: the listener sends to the test process.
  defp logs(acc \\ []) do
    receive do
      {:log, x} -> logs([x | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # formidable's IncomingForm: the multipart parts by field name.
  defp parse_multipart(conn) do
    [content_type] = Plug.Conn.get_req_header(conn, "content-type")
    {:ok, "multipart", "form-data", %{"boundary" => boundary}} = Plug.Conn.Utils.content_type(content_type)

    conn.assigns.post_body
    |> :binary.split("--" <> boundary, [:global])
    |> Enum.drop(1)
    |> Enum.reject(&String.starts_with?(&1, "--"))
    |> Map.new(fn "\r\n" <> part ->
      [head, content] = :binary.split(part, "\r\n\r\n")
      content = binary_part(content, 0, byte_size(content) - 2)
      [_, name] = Regex.run(~r/;\s*name="([^"]*)"/i, head)
      {name, %{size: byte_size(content)}}
    end)
  end
end
