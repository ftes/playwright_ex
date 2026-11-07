defmodule PlaywrightEx.Page.PageAriaSnapshotJsonTest do
  @upstream "tests/page/page-aria-snapshot-json.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Expect
  alias PlaywrightEx.Locator
  alias PlaywrightEx.Page
  alias PlaywrightEx.Utils

  @moduletag :page

  defp find_node(nodes, predicate) do
    Enum.find_value(nodes, fn
      node when is_binary(node) -> nil
      node -> if predicate.(node), do: node, else: find_node(node["children"] || [], predicate)
    end)
  end

  test "AR-096 should snapshot roles, names and text", %{page: page} do
    Page.set_content!(page, """
      <h1>title</h1>
      <ul aria-label="my list">
        <li>one</li>
        <li>two</li>
      </ul>
    """)

    assert Page.aria_snapshot_json!(page) == [
             %{"role" => "heading", "name" => "title", "level" => 1},
             %{
               "role" => "list",
               "name" => "my list",
               "children" => [
                 %{"role" => "listitem", "text" => "one"},
                 %{"role" => "listitem", "text" => "two"}
               ]
             }
           ]
  end

  test "AR-097 should snapshot flags as properties", %{page: page} do
    Page.set_content!(page, """
      <input type="checkbox" title="Check" checked>
      <button disabled>Click</button>
    """)

    assert Page.aria_snapshot_json!(page) == [
             %{"role" => "checkbox", "name" => "Check", "checked" => true},
             %{"role" => "button", "name" => "Click", "disabled" => true}
           ]
  end

  test "AR-098 should snapshot link url and textbox value", %{page: page} do
    Page.set_content!(page, """
      <a href="https://example.com/">Link</a>
      <input title="Input" value="hello">
    """)

    assert Page.aria_snapshot_json!(page) == [
             %{"role" => "link", "name" => "Link", "url" => "https://example.com/"},
             %{"role" => "textbox", "name" => "Input", "text" => "hello"}
           ]
  end

  test "AR-099 should snapshot text fragments in children", %{page: page} do
    Page.set_content!(page, ~s(<p>Hello <a href="/link">world</a> again</p>))

    assert Page.aria_snapshot_json!(page) == [
             %{
               "role" => "paragraph",
               "children" => [
                 "Hello",
                 %{"role" => "link", "name" => "world", "url" => "/link"},
                 "again"
               ]
             }
           ]
  end

  test "AR-100 should snapshot top-level text fragments as text nodes", %{page: page} do
    Page.set_content!(page, "Hello <button>One</button> again")

    assert Page.aria_snapshot_json!(page) == [
             %{"role" => "text", "text" => "Hello"},
             %{"role" => "button", "name" => "One"},
             %{"role" => "text", "text" => "again"}
           ]
  end

  test "AR-101 should generate refs in ai mode", %{page: page} do
    Page.set_content!(page, """
      <button>One</button>
      <button>Two</button>
    """)

    assert Page.aria_snapshot_json!(page, mode: "ai") == [
             %{
               "role" => "generic",
               "active" => true,
               "ref" => "e1",
               "children" => [
                 %{"role" => "button", "name" => "One", "ref" => "e2"},
                 %{"role" => "button", "name" => "Two", "ref" => "e3"}
               ]
             }
           ]

    Expect.to_have_text!(Page.get_by_ref(page, "e2"), "One")
  end

  test "AR-102 should mark clickable elements with cursor in ai mode", %{page: page} do
    Page.set_content!(page, ~s(<button style="cursor: pointer">One</button>))
    json = Page.aria_snapshot_json!(page, mode: "ai")
    button = find_node(json, &(&1["role"] == "button"))
    assert button["cursor"] == "pointer"
  end

  test "AR-103 should snapshot iframes in ai mode", %{page: page} do
    Page.set_content!(page, """
      <h1>Hello</h1>
      <iframe srcdoc="<button>In frame</button>"></iframe>
    """)

    json = Page.aria_snapshot_json!(page, mode: "ai")
    iframe = find_node(json, &(&1["role"] == "iframe"))
    Utils.assert_truthy(iframe["ref"])
    button = find_node(iframe["children"], &(&1["role"] == "button"))
    assert button["name"] == "In frame"
    assert button["ref"] =~ ~r/^f\d+e\d+$/
  end

  test "AR-104 should limit depth", %{page: page} do
    Page.set_content!(page, "<ul><li><button>One</button></li></ul>")

    assert Page.aria_snapshot_json!(page, depth: 1) == [
             %{
               "role" => "list",
               "children" => [
                 %{"role" => "listitem"}
               ]
             }
           ]
  end

  test "AR-105 should include boxes when requested", %{page: page} do
    Page.set_content!(page, "<button>One</button>")
    json = Page.aria_snapshot_json!(page, boxes: true)
    button = find_node(json, &(&1["role"] == "button"))

    assert %{"x" => x, "y" => y, "width" => width, "height" => height} = button["box"]
    assert map_size(button["box"]) == 4
    assert is_number(x) and is_number(y) and is_number(width) and is_number(height)
    assert width > 0
    assert height > 0
  end

  test "AR-106 should snapshot a locator", %{page: page} do
    Page.set_content!(page, """
      <h1>title</h1>
      <ul>
        <li>one</li>
        <li>two</li>
      </ul>
    """)

    assert Locator.aria_snapshot_json!(Page.locator(page, "ul")) == [
             %{
               "role" => "list",
               "children" => [
                 %{"role" => "listitem", "text" => "one"},
                 %{"role" => "listitem", "text" => "two"}
               ]
             }
           ]
  end
end
