defmodule PlaywrightEx.Utils do
  @upstream "tests/config/utils.ts"
  @moduledoc "Port of upstream `#{@upstream}`: helpers of the mirrored specs, on the public API."

  alias PlaywrightEx.ElementHandle
  alias PlaywrightEx.JSHandle
  alias PlaywrightEx.Page

  def attach_frame(page, frame_id, url) do
    handle =
      Page.evaluate_handle!(
        page,
        """
        async ({ frameId, url }) => {
          const frame = document.createElement('iframe');
          frame.src = url;
          frame.id = frameId;
          document.body.appendChild(frame);
          await new Promise(x => frame.onload = x);
          return frame;
        }
        """,
        %{frameId: frame_id, url: url}
      )

    ElementHandle.content_frame!(JSHandle.as_element(handle))
  end

  def detach_frame(page, frame_id) do
    Page.evaluate!(page, "frameId => { document.getElementById(frameId).remove(); }", frame_id)
  end

  def verify_viewport(page, width, height) do
    import ExUnit.Assertions
    assert Page.viewport_size(page).width == width
    assert Page.viewport_size(page).height == height
    assert Page.evaluate!(page, "window.innerWidth") == width
    assert Page.evaluate!(page, "window.innerHeight") == height
  end

  # expectedSSLError, isBidiChannel, chromiumVersionLessThan, suppressCertificateWarning  -- not ported: not needed yet
  # parseTraceCoverage, parseTraceRaw, parseTrace, parseHar  -- not ported: Tracing
  # waitForTestLog  -- not ported: ConsoleMessage

  def rafraf(target, count \\ 1) do
    for _ <- 1..count//1 do
      target.__struct__
      |> facade()
      |> apply(:evaluate!, [
        target,
        "async () => { await new Promise(f => window.builtins.requestAnimationFrame(() => window.builtins.requestAnimationFrame(f))); }"
      ])
    end

    nil
  end

  def ensure_some_frames(page) do
    rafraf(page, 100)
    Page.screenshot!(page)
  end

  def round_box(box) do
    %{x: round(box.x), y: round(box.y), width: round(box.width), height: round(box.height)}
  end

  # unshift, stripAnsi, inheritAndCleanEnv  -- not ported: not needed yet

  # `Page | Frame`: the facade module of a client handle.
  defp facade(PlaywrightEx.Client.Page), do: PlaywrightEx.Page
  defp facade(PlaywrightEx.Client.Frame), do: PlaywrightEx.Frame
end
