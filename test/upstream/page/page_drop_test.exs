defmodule PlaywrightEx.Page.PageDropTest do
  @upstream "tests/page/page-drop.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page

  @moduletag :page

  # it.skip(({ isAndroid }) => isAndroid, 'No drag&drop on Android.');  -- not Android

  defp setup_dropzone(page) do
    Page.set_content!(page, """
      <style>#dropzone { width: 300px; height: 200px; border: 2px dashed #888; }</style>
      <div id="dropzone"></div>
      <script>
        window.__dropInfo = null;
        const zone = document.getElementById('dropzone');
        zone.addEventListener('dragenter', e => e.preventDefault());
        zone.addEventListener('dragover', e => e.preventDefault());
        zone.addEventListener('drop', async e => {
          e.preventDefault();
          const files = [];
          for (const file of e.dataTransfer.files)
            files.push({ name: file.name, type: file.type, size: file.size, text: await file.text() });
          const data = {};
          for (const t of e.dataTransfer.types) {
            if (t !== 'Files')
              data[t] = e.dataTransfer.getData(t);
          }
          window.__dropInfo = { files, data };
        });
      </script>
    """)
  end

  defp get_drop_info(page) do
    page |> Page.wait_for_function!("() => window.__dropInfo") |> JSHandle.json_value!()
  end

  test "should drop a file payload", %{page: page} do
    setup_dropzone(page)

    Locator.drop!(Page.locator(page, "#dropzone"), %{
      files: %{name: "note.txt", mimeType: "text/plain", buffer: "hello"}
    })

    assert get_drop_info(page) == %{
             "files" => [%{"name" => "note.txt", "type" => "text/plain", "size" => 5, "text" => "hello"}],
             "data" => %{}
           }
  end

  test "should drop multiple file payloads", %{page: page} do
    setup_dropzone(page)

    Locator.drop!(Page.locator(page, "#dropzone"), %{
      files: [
        %{name: "a.txt", mimeType: "text/plain", buffer: "AAA"},
        %{name: "b.txt", mimeType: "text/plain", buffer: "BB"}
      ]
    })

    info = get_drop_info(page)
    assert Enum.map(info["files"], &[&1["name"], &1["text"]]) == [["a.txt", "AAA"], ["b.txt", "BB"]]
  end

  @tag :tmp_dir
  test "should drop a file by local path", %{page: page, tmp_dir: tmp_dir} do
    setup_dropzone(page)
    file_path = Path.join(tmp_dir, "hello.txt")
    File.write!(file_path, "path-content")
    Locator.drop!(Page.locator(page, "#dropzone"), %{files: file_path})
    info = get_drop_info(page)
    assert length(info["files"]) == 1
    assert hd(info["files"])["name"] == "hello.txt"
    assert hd(info["files"])["text"] == "path-content"
  end

  test "should drop clipboard-like data", %{page: page} do
    setup_dropzone(page)

    Locator.drop!(Page.locator(page, "#dropzone"), %{
      data: %{
        "text/plain" => "hello world",
        "text/uri-list" => "https://example.com"
      }
    })

    info = get_drop_info(page)
    assert info["files"] == []
    assert info["data"]["text/plain"] == "hello world"
    assert info["data"]["text/uri-list"] == "https://example.com"
  end

  test "should drop files and data together", %{page: page} do
    setup_dropzone(page)

    Locator.drop!(Page.locator(page, "#dropzone"), %{
      files: %{name: "mix.txt", mimeType: "text/plain", buffer: "mix"},
      data: %{"text/plain" => "label"}
    })

    info = get_drop_info(page)
    assert hd(info["files"])["text"] == "mix"
    assert info["data"]["text/plain"] == "label"
  end

  test "should throw when target does not accept drop", %{page: page} do
    # Dropzone without preventDefault on dragover.
    Page.set_content!(page, """
      <div id="dropzone" style="width: 200px; height: 100px;"></div>
    """)

    assert {:error, error} = Locator.drop(Page.locator(page, "#dropzone"), %{data: %{"text/plain" => "nope"}})
    assert Exception.message(error) =~ ~r/drop target did not accept the drop/i
  end

  test "should throw when neither files nor data provided", %{page: page} do
    setup_dropzone(page)
    assert {:error, error} = Locator.drop(Page.locator(page, "#dropzone"), %{})
    assert Exception.message(error) =~ ~r/At least one of "files" or "data"/
  end
end
