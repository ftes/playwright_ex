defmodule PlaywrightEx.Library.Events.EventsListTest do
  @upstream "tests/library/events/events-list.spec.ts"
  use PlaywrightEx.UpstreamCase, async: true

  alias PlaywrightEx.Client.EventEmitter
  alias PlaywrightEx.Runtime.EventLoop

  # `new EventEmitter()` runs on the one JS thread: the playwright fixture's loop.
  defp new_emitter(playwright), do: EventLoop.with_baton(playwright.loop, &EventEmitter.new/0)

  describe "EventEmitter" do
    test "should maintain event names correctly", %{playwright: playwright} do
      e = new_emitter(playwright)
      m = fn _ -> nil end
      EventEmitter.on(e, "foo", fn _ -> :foo end)
      assert length(EventEmitter.event_names(e)) == 1
      assert Enum.at(EventEmitter.event_names(e), 0) == "foo"

      EventEmitter.on(e, "bar", m)
      assert length(EventEmitter.event_names(e)) == 2
      assert Enum.at(EventEmitter.event_names(e), 0) == "foo"
      assert Enum.at(EventEmitter.event_names(e), 1) == "bar"

      EventEmitter.remove_listener(e, "bar", m)
      assert length(EventEmitter.event_names(e)) == 1
      assert Enum.at(EventEmitter.event_names(e), 0) == "foo"

      # Symbol('s')
      s = make_ref()
      EventEmitter.on(e, s, m)
      assert length(EventEmitter.event_names(e)) == 2
      assert Enum.at(EventEmitter.event_names(e), 0) == "foo"
      assert Enum.at(EventEmitter.event_names(e), 1) == s

      EventEmitter.remove_listener(e, s, m)
      assert length(EventEmitter.event_names(e)) == 1
      assert Enum.at(EventEmitter.event_names(e), 0) == "foo"
    end
  end
end
