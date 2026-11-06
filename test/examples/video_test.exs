defmodule PlaywrightEx.Examples.VideoTest do
  # Elixir translations of upstream's JS examples, rendered into the facade docs (see ExampleCase).
  use PlaywrightEx.ExampleCase, async: true

  alias PlaywrightEx.Video

  example "Video",
    js: ~S"""
    console.log(await page.video().path());
    """,
    given: [page: recording_page(browser)] do
    IO.puts(Page.video(page) |> Video.path!())
  end

  # A page of a context that records videos into a tmp dir, removed after the test.
  defp recording_page(browser) do
    dir = Path.join(System.tmp_dir!(), "playwright-ex-videos-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    context = Browser.new_context!(browser, record_video: %{dir: dir})
    on_exit(fn -> BrowserContext.close(context) end)
    BrowserContext.new_page!(context)
  end
end
