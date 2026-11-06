defmodule PlaywrightEx.Examples.CDPSessionTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.CDPSession

  @chromium_only if(PlaywrightEx.TestBrowser.name() != "chromium", do: "CDP sessions are Chromium-only")

  example "CDPSession",
    js: ~S"""
    const client = await page.context().newCDPSession(page);
    await client.send('Animation.enable');
    client.on('Animation.animationCreated', () => console.log('Animation created!'));
    const response = await client.send('Animation.getPlaybackRate');
    console.log('playback rate is ' + response.playbackRate);
    await client.send('Animation.setPlaybackRate', {
      playbackRate: response.playbackRate / 2
    });
    """,
    skip: @chromium_only do
    client = Page.context(page) |> BrowserContext.new_cdp_session!(page)
    CDPSession.send!(client, "Animation.enable")
    CDPSession.on(client, "Animation.animationCreated", fn _ -> IO.puts("Animation created!") end)
    response = CDPSession.send!(client, "Animation.getPlaybackRate")
    IO.puts("playback rate is #{response["playbackRate"]}")
    CDPSession.send!(client, "Animation.setPlaybackRate", %{playbackRate: response["playbackRate"] / 2})
  end

  example "CDPSession.event",
    js: ~S"""
    session.on('event', ({ method, params }) => {
      console.log(`CDP event: ${method}`, params);
    });
    """,
    skip: @chromium_only,
    given: [session: BrowserContext.new_cdp_session!(context, page)] do
    CDPSession.on(session, :event, fn event ->
      IO.puts("CDP event: #{event.method} #{inspect(event[:params])}")
    end)
  end
end
