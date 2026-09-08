defmodule PlaywrightEx.ElementHandleTest do
  use PlaywrightExCase, async: true

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.FilePayload
  alias PlaywrightEx.Frame
  alias PlaywrightEx.Page

  test "sets files on the element from a page file chooser event", %{page: page, frame: frame} do
    :ok =
      set_html(
        frame.guid,
        """
        <input id="file-input" type="file" hidden>
        <button id="choose" onclick="document.getElementById('file-input').click()">Choose file</button>
        """
      )

    :ok = PlaywrightEx.subscribe(page.guid)

    on_exit(fn ->
      PlaywrightEx.unsubscribe(page.guid)
    end)

    assert {:ok, _} =
             Page.update_subscription(page.guid,
               event: :file_chooser,
               enabled: true,
               timeout: @timeout
             )

    assert {:ok, _} = Frame.click(frame.guid, selector: "#choose", timeout: @timeout)

    assert_receive {:playwright_msg,
                    %{
                      guid: page_id,
                      method: :file_chooser,
                      params: %{element: %{guid: element_id}, is_multiple: false}
                    }}

    assert page_id == page.guid

    assert {:ok, _} =
             ElementHandle.set_input_files(element_id,
               payloads: %FilePayload{name: "chosen.txt", mime_type: "text/plain", buffer: "chosen"},
               timeout: @timeout
             )

    assert {:ok, %{"name" => "chosen.txt", "contents" => "chosen"}} =
             eval(frame.guid, """
             async () => {
               const file = document.getElementById('file-input').files[0];
               return {name: file.name, contents: await file.text()};
             }
             """)
  end
end
