defmodule PlaywrightEx.Page.PageSetInputFilesTest do
  @upstream "tests/page/page-set-input-files.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.TestServer

  @moduletag :page

  @read_first_file """
  e => {
    const reader = new FileReader();
    const promise = new Promise(fulfill => reader.onload = fulfill);
    reader.readAsText(e.files[0]);
    return promise.then(() => reader.result);
  }
  """

  test "IF-001 should upload the file", %{page: page, server: server, asset: asset} do
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    file_path = Path.relative_to_cwd(asset.("file-to-upload.txt"))
    input = Page.query_selector!(page, "input")
    ElementHandle.set_input_files!(input, file_path)
    assert Page.evaluate!(page, "e => e.files[0].name", input) == "file-to-upload.txt"
    assert Page.evaluate!(page, @read_first_file, input) == "contents of the file"
  end

  @tag :tmp_dir
  test "IF-002 should upload a folder", %{page: page, server: server, tmp_dir: tmp_dir} do
    # test.skip(isAndroid);  -- not Android
    # test.skip(isFrozenWebkit);  -- we run a current browser
    Page.goto!(page, server.prefix <> "/input/folderupload.html")
    input = Page.query_selector!(page, "input")
    dir = Path.join(tmp_dir, "file-upload-test")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "file1.txt"), "file1 content")
    File.write!(Path.join(dir, "file2"), "file2 content")
    File.mkdir!(Path.join(dir, "sub-dir"))
    File.write!(Path.join([dir, "sub-dir", "really.txt"]), "sub-dir file content")
    ElementHandle.set_input_files!(input, dir)

    # Note: this did not work before Chrome 127, see https://issues.chromium.org/issues/345393164.
    assert MapSet.new(Page.evaluate!(page, "e => [...e.files].map(f => f.webkitRelativePath)", input)) ==
             MapSet.new(["file-upload-test/sub-dir/really.txt", "file-upload-test/file1.txt", "file-upload-test/file2"])

    webkit_relative_paths = Page.evaluate!(page, "e => [...e.files].map(f => f.webkitRelativePath)", input)

    for {webkit_relative_path, i} <- Enum.with_index(webkit_relative_paths) do
      content =
        JSHandle.evaluate!(
          input,
          """
          (e, i) => {
            const reader = new FileReader();
            const promise = new Promise(fulfill => reader.onload = fulfill);
            reader.readAsText(e.files[i]);
            return promise.then(() => reader.result);
          }
          """,
          i
        )

      assert content == File.read!(Path.join([dir, "..", webkit_relative_path]))
    end
  end

  @tag :tmp_dir
  test "IF-004 should upload a folder and throw for multiple directories", %{
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    # test.skip(isAndroid);  -- not Android
    # test.skip(isFrozenWebkit);  -- we run a current browser
    Page.goto!(page, server.prefix <> "/input/folderupload.html")
    input = Page.query_selector!(page, "input")
    dir = Path.join(tmp_dir, "file-upload-test")
    File.mkdir_p!(Path.join(dir, "folder1"))
    File.write!(Path.join([dir, "folder1", "file1.txt"]), "file1 content")
    File.mkdir_p!(Path.join(dir, "folder2"))
    File.write!(Path.join([dir, "folder2", "file2.txt"]), "file2 content")

    {:error, error} = ElementHandle.set_input_files(input, [Path.join(dir, "folder1"), Path.join(dir, "folder2")])
    assert Exception.message(error) =~ "Multiple directories are not supported"
  end

  @tag :tmp_dir
  test "IF-005 should throw if a directory and files are passed", %{page: page, server: server, tmp_dir: tmp_dir} do
    # test.skip(isAndroid);  -- not Android
    # test.skip(isFrozenWebkit);  -- we run a current browser
    Page.goto!(page, server.prefix <> "/input/folderupload.html")
    input = Page.query_selector!(page, "input")
    dir = Path.join(tmp_dir, "file-upload-test")
    File.mkdir_p!(Path.join(dir, "folder1"))
    File.write!(Path.join([dir, "folder1", "file1.txt"]), "file1 content")

    {:error, error} =
      ElementHandle.set_input_files(input, [Path.join(dir, "folder1"), Path.join([dir, "folder1", "file1.txt"])])

    assert Exception.message(error) =~ "File paths must be all files or a single directory"
  end

  @tag :tmp_dir
  test "IF-006 should throw when uploading a folder in a normal file upload input", %{
    page: page,
    server: server,
    tmp_dir: tmp_dir
  } do
    # test.skip(isAndroid);  -- not Android
    # test.skip(isFrozenWebkit);  -- we run a current browser
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    input = Page.query_selector!(page, "input")
    dir = Path.join(tmp_dir, "file-upload-test")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "file1.txt"), "file1 content")
    {:error, error} = ElementHandle.set_input_files(input, dir)
    assert Exception.message(error) =~ "File input does not support directories, pass individual files instead"
  end

  test "IF-007 should throw when uploading a file in a directory upload input", %{
    page: page,
    server: server,
    asset: asset
  } do
    # test.skip(isAndroid);  -- not Android
    # test.skip(isFrozenWebkit);  -- we run a current browser
    Page.goto!(page, server.prefix <> "/input/folderupload.html")
    input = Page.query_selector!(page, "input")
    {:error, error} = ElementHandle.set_input_files(input, asset.("file to upload.txt"))
    assert Exception.message(error) =~ "[webkitdirectory] input requires passing a path to a directory"
  end

  test "IF-008 should upload a file after popup", %{page: page, server: server, asset: asset} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/29923' }
    Page.goto!(page, server.prefix <> "/input/fileupload.html")

    popup =
      Page.expect_event!(page, :popup, fn ->
        Page.evaluate!(page, "() => window['__popup'] = window.open('about:blank')")
      end)

    Page.close!(popup)

    file_path = Path.relative_to_cwd(asset.("file-to-upload.txt"))
    input = Page.query_selector!(page, "input")
    ElementHandle.set_input_files!(input, file_path)
    assert Page.evaluate!(page, "e => e.files[0].name", input) == "file-to-upload.txt"
  end

  @tag :tmp_dir
  # test.slow()
  @tag timeout: @slow_timeout
  test "IF-009 should upload large file", %{page: page, server: server, tmp_dir: tmp_dir} do
    # test.skip(isAndroid);  -- not Android
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    upload_file = Path.join(tmp_dir, "200MB.zip")
    write_200mb(upload_file)
    input = Page.locator(page, ~s|input[type="file"]|)
    events = Locator.evaluate_handle!(input, record_input_and_change_events())
    Locator.set_input_files!(input, upload_file)
    assert Locator.evaluate!(input, "e => e.files[0].name") == "200MB.zip"
    assert JSHandle.evaluate!(events, "e => e") == ["input", "change"]
    test_pid = self()

    TestServer.set_route(server, "/upload", fn conn ->
      send(test_pid, {:files, parse_multipart(conn)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.click!(page, "input[type=submit]")
    assert_receive {:files, %{"file1" => file1}}, 60_000
    assert file1.original_filename == "200MB.zip"
    assert file1.size == 200 * 1024 * 1024
    File.rm!(upload_file)
  end

  test "IF-010 should throw an error if the file does not exist", %{page: page, server: server} do
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    input = Page.query_selector!(page, "input")
    # deviation: Elixir's File error, not Node's text.
    {:error, error} = ElementHandle.set_input_files(input, "i actually do not exist.txt")
    assert %File.Error{reason: :enoent, path: "i actually do not exist.txt"} = error
  end

  @tag :tmp_dir
  # test.slow()
  @tag timeout: @slow_timeout
  test "IF-011 should upload large file with relative path", %{page: page, server: server, tmp_dir: tmp_dir} do
    # test.skip(isAndroid);  -- not Android
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    upload_file = Path.join(tmp_dir, "200MB.zip")
    write_200mb(upload_file)
    input = Page.locator(page, ~s|input[type="file"]|)
    events = Locator.evaluate_handle!(input, record_input_and_change_events())
    relative_upload_path = Path.relative_to_cwd(upload_file)
    refute Path.type(relative_upload_path) == :absolute
    Locator.set_input_files!(input, relative_upload_path)
    assert Locator.evaluate!(input, "e => e.files[0].name") == "200MB.zip"
    assert JSHandle.evaluate!(events, "e => e") == ["input", "change"]
    test_pid = self()

    TestServer.set_route(server, "/upload", fn conn ->
      send(test_pid, {:files, parse_multipart(conn)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.click!(page, "input[type=submit]")
    assert_receive {:files, %{"file1" => file1}}, 60_000
    assert file1.original_filename == "200MB.zip"
    assert file1.size == 200 * 1024 * 1024
    File.rm!(upload_file)
  end

  test "IF-012 should upload the file with spaces in name", %{page: page, server: server, asset: asset} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/17451' }
    Page.goto!(page, server.prefix <> "/input/fileupload.html")
    file_path = Path.relative_to_cwd(asset.("file to upload.txt"))
    input = Page.query_selector!(page, "input")
    ElementHandle.set_input_files!(input, file_path)
    assert Page.evaluate!(page, "e => e.files[0].name", input) == "file to upload.txt"
    assert Page.evaluate!(page, @read_first_file, input) == "contents of the file"
  end

  test "IF-013 should work @smoke", %{page: page, asset: asset} do
    Page.set_content!(page, "<input type=file>")
    Page.set_input_files!(page, "input", asset.("file-to-upload.txt"))
    assert Page.eval_on_selector!(page, "input", "input => input.files.length") == 1
    assert Page.eval_on_selector!(page, "input", "input => input.files[0].name") == "file-to-upload.txt"
  end

  test "IF-014 should set from memory", %{page: page} do
    Page.set_content!(page, "<input type=file>")
    Page.set_input_files!(page, "input", %{name: "test.txt", mimeType: "text/plain", buffer: "this is a test"})
    assert Page.eval_on_selector!(page, "input", "input => input.files.length") == 1
    assert Page.eval_on_selector!(page, "input", "input => input.files[0].name") == "test.txt"
  end

  test "IF-015 should work with CSP", %{page: page, server: server, asset: asset} do
    TestServer.set_csp(server, "/empty.html", ~s(default-src "none"))
    Page.goto!(page, server.empty_page)
    Page.set_content!(page, "<input type=file>")
    Page.set_input_files!(page, "input", asset.("file-to-upload.txt"))
    assert Page.eval_on_selector!(page, "input", "input => input.files.length") == 1
    assert Page.eval_on_selector!(page, "input", "input => input.files[0].name") == "file-to-upload.txt"
  end

  test "IF-016 should detect mime type", %{page: page, server: server, asset: asset} do
    test_pid = self()

    TestServer.set_route(server, "/upload", fn conn ->
      send(test_pid, {:files, parse_multipart(conn)})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <form action="/upload" method="post" enctype="multipart/form-data" >
      <input type="file" name="file1">
      <input type="file" name="file2">
      <input type="submit" value="Submit">
    </form>
    """)

    page |> Page.query_selector!("input[name=file1]") |> ElementHandle.set_input_files!(asset.("file-to-upload.txt"))
    page |> Page.query_selector!("input[name=file2]") |> ElementHandle.set_input_files!(asset.("pptr.png"))
    request = TestServer.wait_for_request(server, "/upload")
    Page.click!(page, "input[type=submit]")
    Task.await(request, :infinity)
    assert_receive {:files, %{"file1" => file1, "file2" => file2}}
    assert file1.original_filename == "file-to-upload.txt"
    assert file1.mimetype == "text/plain"
    assert file1.content == File.read!(asset.("file-to-upload.txt"))
    assert file2.original_filename == "pptr.png"
    assert file2.mimetype == "image/png"
    assert file2.content == File.read!(asset.("pptr.png"))
  end

  # @see https://github.com/microsoft/playwright/issues/4704
  test "IF-017 should not trim big uploaded files", %{page: page, server: server} do
    test_pid = self()

    TestServer.set_route(server, "/upload", fn conn ->
      send(test_pid, {:files, parse_multipart(conn)})
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

  test "IF-018 should emit input and change events", %{page: page, asset: asset} do
    test = self()

    Page.expose_function!(page, "eventHandled", fn e ->
      send(test, {:event, e})
      nil
    end)

    Page.set_content!(page, """
    <input id=input type=file></input>
    <script>
      input.addEventListener('input', e => eventHandled({ type: e.type }));
      input.addEventListener('change', e => eventHandled({ type: e.type }));
    </script>
    """)

    ElementHandle.set_input_files!(Page.query_selector!(page, "input"), asset.("file-to-upload.txt"))
    # The events are reported before setInputFiles returns.
    assert_received {:event, first}
    assert_received {:event, second}
    refute_received {:event, _}
    assert first["type"] == "input"
    assert second["type"] == "change"
  end

  test "IF-019 input event.composed should be true and cross shadow dom boundary", %{page: page, server: server} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/28726' }
    Page.goto!(page, server.empty_page)

    Page.set_content!(page, """
    <body><script>
      const div = document.createElement('div');
      const shadowRoot = div.attachShadow({mode: 'open'});
      shadowRoot.innerHTML = '<input type=file></input>';
      document.body.appendChild(div);
    </script></body>
    """)

    page
    |> Page.locator("body")
    |> Locator.evaluate!("""
    select => {
      window.firedBodyEvents = [];
      for (const event of ['input', 'change']) {
        select.addEventListener(event, e => {
          window.firedBodyEvents.push(e.type + ':' + e.composed);
        }, false);
      }
    }
    """)

    page
    |> Page.locator("input")
    |> Locator.evaluate!("""
    select => {
      window.firedEvents = [];
      for (const event of ['input', 'change']) {
        select.addEventListener(event, e => {
          window.firedEvents.push(e.type + ':' + e.composed);
        }, false);
      }
    }
    """)

    page
    |> Page.locator("input")
    |> Locator.set_input_files!(%{name: "test.txt", mimeType: "text/plain", buffer: "this is a test"})

    assert Page.evaluate!(page, "() => window['firedEvents']") == ["input:true", "change:false"]
    assert Page.evaluate!(page, "() => window['firedBodyEvents']") == ["input:true"]
  end

  test "IF-020 input should trigger events when files changed second time", %{page: page, asset: asset} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/20079' }
    Page.set_content!(page, "<input type=file multiple=true/>")

    input = Page.locator(page, "input")
    events = Locator.evaluate_handle!(input, record_input_and_change_events())

    Locator.set_input_files!(input, asset.("file-to-upload.txt"))
    assert Locator.evaluate!(input, "e => e.files[0].name") == "file-to-upload.txt"
    assert JSHandle.evaluate!(events, "e => e") == ["input", "change"]

    JSHandle.evaluate!(events, "e => e.length = 0")

    Locator.set_input_files!(input, asset.("pptr.png"))
    assert Locator.evaluate!(input, "e => e.files[0].name") == "pptr.png"
    assert JSHandle.evaluate!(events, "e => e") == ["input", "change"]
  end

  test "IF-021 should preserve lastModified timestamp", %{page: page, asset: asset} do
    # annotation: { type: 'issue', description: 'https://github.com/microsoft/playwright/issues/27452' }
    Page.set_content!(page, "<input type=file multiple=true/>")
    input = Page.locator(page, "input")
    files = ["file-to-upload.txt", "file-to-upload-2.txt"]
    Locator.set_input_files!(input, Enum.map(files, &asset.(&1)))
    assert Locator.evaluate!(input, "e => [...e.files].map(f => f.name)") == files
    timestamps = Locator.evaluate!(input, "e => [...e.files].map(f => f.lastModified)")
    # Erlang has whole seconds only: within the 1000ms tolerance below.
    expected_timestamps = Enum.map(files, &(File.stat!(asset.(&1), time: :posix).mtime * 1000))
    # On Linux browser sometimes reduces the timestamp by 1ms: 1696272058110.0715  -> 1696272058109 or even
    # rounds it to seconds in WebKit: 1696272058110 -> 1696272058000.
    for {timestamp, expected} <- Enum.zip(timestamps, expected_timestamps) do
      assert abs(timestamp - expected) <= 1000,
             "expected: #{inspect(expected_timestamps)}; actual: #{inspect(timestamps)}"
    end
  end

  defp record_input_and_change_events do
    """
    e => {
      const events = [];
      e.addEventListener('input', () => events.push('input'));
      e.addEventListener('change', () => events.push('change'));
      return events;
    }
    """
  end

  defp write_200mb(path) do
    str = String.duplicate("A", 4 * 1024)
    File.open!(path, [:write, :raw, :binary], fn file -> for _ <- 1..(50 * 1024), do: IO.binwrite(file, str) end)
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

      headers =
        Map.new(String.split(head, "\r\n"), fn line ->
          [key, value] = String.split(line, ":", parts: 2)
          {String.downcase(key), String.trim(value)}
        end)

      disposition = headers["content-disposition"]
      [_, name] = Regex.run(~r/;\s*name="([^"]*)"/, disposition)
      filename = with [_, filename] <- Regex.run(~r/;\s*filename="([^"]*)"/, disposition), do: filename

      {name,
       %{original_filename: filename, mimetype: headers["content-type"], size: byte_size(content), content: content}}
    end)
  end
end
