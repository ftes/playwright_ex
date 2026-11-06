defmodule PlaywrightEx.Examples.ScreencastTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Screencast

  example "Screencast.start",
    js: ~S"""
    // Record video
    await page.screencast.start({ path: 'video.webm', size: { width: 1280, height: 800 } });
    // ... perform actions ...
    await page.screencast.stop();
    """,
    writes: ["video.webm"] do
    # Record video
    Page.screencast(page) |> Screencast.start!(path: "video.webm", size: %{width: 1280, height: 800})
    # ... perform actions ...
    Page.screencast(page) |> Screencast.stop!()
  end

  example "Screencast.start",
    js: ~S"""
    // Capture frames
    await page.screencast.start({
      onFrame: ({ data, timestamp, viewportWidth, viewportHeight }) => {
        console.log(`frame size: ${data.length} (${viewportWidth}x${viewportHeight}) at ${timestamp}`);
      },
      size: { width: 800, height: 600 },
    });
    // ... perform actions ...
    await page.screencast.stop();
    """ do
    # Capture frames
    Page.screencast(page)
    |> Screencast.start!(
      on_frame: fn %{data: data, timestamp: timestamp, viewportWidth: width, viewportHeight: height} ->
        IO.puts("frame size: #{byte_size(data)} (#{width}x#{height}) at #{timestamp}")
      end,
      size: %{width: 800, height: 600}
    )

    # ... perform actions ...
    Page.screencast(page) |> Screencast.stop!()
  end

  example "Screencast.showActions",
    js: ~S"""
    await page.screencast.showActions({
      style: {
        point: 'width: 20px; height: 20px; border-radius: 50%; background: red',
        highlight: 'outline: 2px solid #333; background: rgba(0, 128, 255, .15)',
        title: 'font-size: 16px',
      },
    });
    """ do
    Page.screencast(page)
    |> Screencast.show_actions!(
      style: %{
        point: "width: 20px; height: 20px; border-radius: 50%; background: red",
        highlight: "outline: 2px solid #333; background: rgba(0, 128, 255, .15)",
        title: "font-size: 16px"
      }
    )
  end
end
