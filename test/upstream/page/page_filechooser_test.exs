defmodule PlaywrightEx.Page.PageFilechooserTest do
  @upstream "tests/page/page-filechooser.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  import PlaywrightEx.Utils, only: [attach_frame: 3]

  alias PlaywrightEx.AbortController
  alias PlaywrightEx.FileChooser
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Promise
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
    Task.async(fn -> promise |> Promise.await!() |> FileChooser.set_files!(files) end)
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
  test "should upload multiple large files", %{page: page, server: server, tmp_dir: tmp_dir} do
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

  test "should emit event once", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    test = self()
    Page.once(page, :file_chooser, &send(test, {:chooser, &1}))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "should emit event via prepend", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    test = self()
    Page.prepend_listener(page, :file_chooser, &send(test, {:chooser, &1}))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "should emit event for iframe", %{page: page, server: server} do
    frame = attach_frame(page, "frame1", server.empty_page)
    Frame.set_content!(frame, "<input type=file>")
    test = self()
    Page.once(page, :file_chooser, &send(test, {:chooser, &1}))
    Frame.click!(frame, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "should emit event on/off", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    Page.on(page, :file_chooser, self_removing_listener(page, &Page.off/3, self()))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "should emit event addListener/removeListener", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    Page.add_listener(page, :file_chooser, self_removing_listener(page, &Page.remove_listener/3, self()))
    Page.click!(page, "input")
    assert_receive {:chooser, chooser}
    assert chooser
  end

  test "should work when file input is attached to DOM", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    chooser = Promise.await!(promise)
    assert chooser
  end

  test "should work when file input is not attached to DOM", %{page: page, asset: asset} do
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

    Task.await(set_files, :infinity)
    assert content == "contents of the file"
  end

  test "should not throw when filechooser belongs to iframe", %{page: page, server: server} do
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

  test "should not throw when frame is detached immediately", %{page: page, server: server} do
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

  test "should respect timeout", %{page: page} do
    {:error, error} = page |> Page.wait_for_event(:file_chooser, timeout: 1) |> Promise.await()
    assert %TimeoutError{} = error
  end

  test "should respect default timeout when there is no custom timeout", %{page: page} do
    Page.set_default_timeout(page, 1)
    {:error, error} = page |> Page.wait_for_event(:file_chooser) |> Promise.await()
    assert %TimeoutError{} = error
  end

  test "should prioritize exact timeout over default timeout", %{page: page} do
    Page.set_default_timeout(page, 0)
    {:error, error} = page |> Page.wait_for_event(:file_chooser, timeout: 1) |> Promise.await()
    assert %TimeoutError{} = error
  end

  test "should work with no timeout", %{page: page} do
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

  test "should abort with signal", %{page: page} do
    controller = AbortController.new()
    promise = Page.wait_for_event(page, :file_chooser, signal: AbortController.signal(controller))
    AbortController.abort(controller, "Aborted by user")
    {:error, error} = Promise.await(promise)
    assert error.name == "AbortError"
    assert error.cause == "Aborted by user"
  end

  test "should return the same file chooser when there are many watchdogs simultaneously", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    promise1 = Page.wait_for_event(page, :file_chooser)
    promise2 = Page.wait_for_event(page, :file_chooser)
    Page.eval_on_selector!(page, "input", "input => input.click()")
    file_chooser1 = Promise.await!(promise1)
    file_chooser2 = Promise.await!(promise2)
    assert file_chooser1 == file_chooser2
  end

  test "should accept single file", %{page: page, asset: asset} do
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
  test "should not trim big uploaded files", %{page: page, server: server} do
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

  test "should be able to read selected file", %{page: page, asset: asset} do
    Page.set_content!(page, "<input type=file>")
    set_files = set_files_on_chooser(page, asset.("file-to-upload.txt"))
    content = Page.eval_on_selector!(page, "input", @read_selected_file)
    Task.await(set_files, :infinity)
    assert content == "contents of the file"
  end

  test "should be able to reset selected files with empty file list", %{page: page, asset: asset} do
    Page.set_content!(page, "<input type=file>")
    set_files1 = set_files_on_chooser(page, asset.("file-to-upload.txt"))
    file_length1 = Page.eval_on_selector!(page, "input", @pick_files_length)
    Task.await(set_files1, :infinity)
    assert file_length1 == 1
    set_files2 = set_files_on_chooser(page, [])
    file_length2 = Page.eval_on_selector!(page, "input", @pick_files_length)
    Task.await(set_files2, :infinity)
    assert file_length2 == 0
  end

  test "should work for single file pick", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    file_chooser = Promise.await!(promise)
    assert FileChooser.is_multiple(file_chooser) == false
  end

  test "should work for \"multiple\"", %{page: page} do
    Page.set_content!(page, "<input multiple type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    file_chooser = Promise.await!(promise)
    assert FileChooser.is_multiple(file_chooser) == true
  end

  test "should work for \"webkitdirectory\"", %{page: page} do
    Page.set_content!(page, "<input multiple webkitdirectory type=file>")
    promise = Page.wait_for_event(page, :file_chooser)
    Page.click!(page, "input")
    file_chooser = Promise.await!(promise)
    assert FileChooser.is_multiple(file_chooser) == true
  end

  # https://github.com/microsoft/playwright/issues/11375
  # test.skip(browserName === 'chromium' && browserMajorVersion < 99): the pinned browsers are newer.
  test "should emit event after navigation", %{page: page, server: server} do
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
  test "should trigger listener added before navigation", %{page: page, server: server} do
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
