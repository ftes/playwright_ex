defmodule PlaywrightEx.Isomorphic.ProtocolFormatterTest do
  # The titles, subtitles and params of the `pw:api` steps (upstream's protocolFormatter, which
  # has no spec of its own: its traces are checked in tests/playwright-test).
  use ExUnit.Case, async: true

  alias PlaywrightEx.Isomorphic.ProtocolFormatter

  defp call(type, method, params \\ %{}, extra \\ %{}),
    do: Map.merge(%{type: type, method: method, params: params}, extra)

  test "a title and subtitle from the metainfo, the selector as a locator" do
    click = call("Frame", "click", %{selector: "internal:role=button[name=\"Go\"i]", button: "right"})
    assert ProtocolFormatter.render_title_for_call(click) == "Click"
    assert ProtocolFormatter.render_subtitle_for_call(click) == "getByRole('button', { name: 'Go' })"
    assert ProtocolFormatter.render_full_title_for_call(click) == "Click getByRole('button', { name: 'Go' })"

    assert ProtocolFormatter.render_params_for_call(click) == %{
             "locator" => "getByRole('button', { name: 'Go' })",
             "button" => "right"
           }

    assert ProtocolFormatter.render_full_title_for_call(click, "python") == ~s[Click get_by_role("button", name="Go")]
  end

  test "a param in the title, alternatives, newlines escaped, an unresolved subtitle left out" do
    assert ProtocolFormatter.render_title_for_call(call("Frame", "type", %{text: "a\nb"})) == ~s(Type "a\\nb")
    clock = call("BrowserContext", "clockRunFor", %{ticksString: "01:00"})
    assert ProtocolFormatter.render_title_for_call(clock) == ~s(Run clock "01:00")

    assert ProtocolFormatter.render_title_for_call(call("BrowserContext", "clockRunFor")) ==
             ~s(Run clock "{ticksNumber|ticksString}")

    assert ProtocolFormatter.render_subtitle_for_call(call("Frame", "click")) == nil
    assert ProtocolFormatter.render_subtitle_for_call(call("Frame", "setContent")) == nil
  end

  test "the call's own title wins, and a method without metainfo is its name" do
    assert ProtocolFormatter.render_title_for_call(
             call("Page", "__waitInfo__", %{}, %{title: ~s(Wait for event "page")})
           ) ==
             ~s(Wait for event "page")

    assert ProtocolFormatter.render_title_for_call(call("Page", "noSuchMethod")) == "noSuchMethod"
  end

  test "urls: host, path and query; data: and about: URLs; a relative one as is" do
    goto = &ProtocolFormatter.render_subtitle_for_call(call("Frame", "goto", %{url: &1}))
    assert goto.("https://Example.com:443/a/b?q=1#h") == "example.com/a/b?q=1"
    assert goto.("http://localhost:8907") == "localhost:8907/"
    assert goto.("data:text/html,<p>x</p>") == "data:"
    assert goto.("about:blank") == "about:blank"
    assert goto.("/relative") == "/relative"
  end

  test "params: renamed, nested, selectors as locators, long strings truncated, none is nil" do
    assert ProtocolFormatter.render_params_for_call(call("Frame", "waitForTimeout", %{waitTimeout: 100})) == %{
             "timeout" => 100
           }

    assert ProtocolFormatter.render_params_for_call(call("Frame", "setContent", %{html: "<p>"})) == nil
    long = String.duplicate("x", 250)
    assert %{"url" => url} = ProtocolFormatter.render_params_for_call(call("Frame", "addScriptTag", %{url: long}))
    assert url == String.duplicate("x", 200) <> "…"
    assert ProtocolFormatter.render_params_for_call(call("Frame", "click")) == nil
    assert ProtocolFormatter.render_params_for_call(%{type: "Frame", method: "click"}) == nil
  end

  test "a group, of the methods that have one" do
    assert ProtocolFormatter.get_action_group(call("Frame", "isVisible")) == "getter"
    assert ProtocolFormatter.get_action_group(call("Frame", "click")) == nil
  end
end
