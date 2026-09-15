defmodule PlaywrightEx.DownloadTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.Artifact
  alias PlaywrightEx.Connection
  alias PlaywrightEx.Download
  alias PlaywrightEx.EventWaiter
  alias PlaywrightEx.Page

  @moduletag :tmp_dir

  test "saves metadata and binary contents repeatedly without consuming the artifact", %{
    page: page,
    frame: frame,
    tmp_dir: dir
  } do
    {:ok, pending} = Page.expect_download(page.guid, timeout: @timeout)
    trigger(frame.guid, "report.csv")
    assert {:ok, %Download{} = download} = Page.await_download(pending)
    assert download.page_id == page.guid
    assert download.suggested_filename == "report.csv"
    assert download.url =~ "blob:"

    for filename <- ["first", "second"] do
      path = Path.join(dir, filename)
      assert :ok = Download.save_as(download, path, timeout: @timeout)
      assert File.read!(path) == <<0, 255, 10, 42>>
    end

    assert {:ok, _} = Download.delete(download, timeout: @timeout)
    assert File.read!(Path.join(dir, "first")) == <<0, 255, 10, 42>>
    assert {:error, _} = Download.save_as(download, Path.join(dir, "deleted"), timeout: @timeout)
  end

  test "a persistent recorder and a one-shot waiter can consume the same event", %{page: page, frame: frame, tmp_dir: dir} do
    PlaywrightEx.subscribe(page.guid)
    _ = Connection.initializer!(PlaywrightEx.Supervisor.Connection, page.guid)
    {:ok, pending} = Page.expect_download(page.guid, timeout: @timeout)
    trigger(frame.guid, "shared.txt")
    assert {:ok, download} = Page.await_download(pending)
    assert_receive {:playwright_msg, %{method: :download} = event}
    recorded_download = Download.from_event(event)
    assert recorded_download == download
    assert :ok = Download.save_as(download, Path.join(dir, "new-api"), timeout: @timeout)
    assert :ok = Artifact.save_as(recorded_download.artifact_guid, Path.join(dir, "existing-api"), timeout: @timeout)
    assert File.read!(Path.join(dir, "existing-api")) == <<0, 255, 10, 42>>
  end

  test "first download survives a second download and page closure before await", %{
    page: page,
    frame: frame,
    tmp_dir: dir
  } do
    {:ok, pending} = Page.expect_download(page.guid, timeout: @timeout)
    {:ok, observer} = Page.expect_download(page.guid, timeout: @timeout)
    trigger(frame.guid, "first.txt")
    assert {:ok, first} = Page.await_download(observer)
    assert :ok = Download.save_as(first, Path.join(dir, "observed"), timeout: @timeout)
    trigger(frame.guid, "second.txt")
    {:ok, _} = Page.close(page.guid, timeout: @timeout)
    assert {:ok, %{suggested_filename: "first.txt"} = download} = Page.await_download(pending)
    assert :ok = Download.save_as(download, Path.join(dir, "first"), timeout: @timeout)
  end

  test "a predicate selects a download by filename", %{page: page, frame: frame, tmp_dir: dir} do
    {:ok, pending} =
      Page.expect_download(page.guid,
        timeout: @timeout,
        predicate: &(&1.suggested_filename == "report.csv")
      )

    trigger(frame.guid, "unrelated.txt")
    trigger(frame.guid, "report.csv")
    assert {:ok, download} = Page.await_download(pending)
    assert download.suggested_filename == "report.csv"
    path = Path.join(dir, "report.csv")
    assert :ok = Download.save_as(download, path, timeout: @timeout)
    assert File.read!(path) == <<0, 255, 10, 42>>
  end

  test "missing downloads time out and later listeners still work", %{page: page, frame: frame} do
    {:ok, pending} = Page.expect_download(page.guid, timeout: 10)
    assert {:error, %{reason: :timeout}} = Page.await_download(pending)
    {:ok, next} = Page.expect_download(page.guid, timeout: @timeout)
    trigger(frame.guid, "next.txt")
    assert {:ok, %{suggested_filename: "next.txt"}} = Page.await_download(next)
    assert :ok = EventWaiter.cancel(next)
  end

  defp trigger(frame, filename) do
    eval(
      frame,
      """
      name => {
        const link = document.createElement('a');
        link.href = URL.createObjectURL(new Blob([new Uint8Array([0, 255, 10, 42])]));
        link.download = name;
        document.body.appendChild(link);
        link.click();
      }
      """,
      filename
    )
  end
end
