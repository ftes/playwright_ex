# Events and waiting

Most waiting is built in: actions wait for their element, `Expect.*` retries, `goto` waits for the
page to load. This guide covers events: a download, a popup, a dialog. Snippets alias
`PlaywrightEx.{Page, Locator, ...}`; the [Concurrency](concurrency.md) guide explains the
processes underneath.

## One event: start the wait, then act

`wait_for_event/3` starts waiting at once and returns a `PlaywrightEx.Promise`. Trigger the event,
then await it:

```elixir
promise = Page.wait_for_event(page, :download)
Page.get_by_text(page, "Export") |> Locator.click!()
download = Promise.await!(promise)
```

The `expect_*` functions do the same with a callback, and read better for one action:

```elixir
download = Page.expect_download!(page, fn -> Page.get_by_text(page, "Export") |> Locator.click!() end)
```

Waiting after the action can miss the event: the click returns when the browser has clicked, and the
download may already have started. [`Page.wait_for_event!/3`](`PlaywrightEx.Page.wait_for_event!/3`)
awaits at once, so use it only for what happens later on its own, such as a timer in the page.

A predicate picks one event out of many, and `timeout:` bounds the wait:

```elixir
save = fn -> Page.get_by_role(page, :button, name: "Save") |> Locator.click!() end
message = Page.expect_console_message!(page, save, predicate: &(ConsoleMessage.text(&1) == "saved"), timeout: 1_000)
```

## Every event: listeners

`on/3` calls a function for every event until `off/3` removes it (pass the same function);
`once/3` removes it after the first. A listener runs in a process of its own, so send what you
need to the process that owns the work:

```elixir
owner = self()
listener = fn request -> send(owner, {:request, Request.method(request), Request.url(request)}) end

Page.on(page, :request, listener)
Page.goto!(page, "/")
assert_receive {:request, "GET", _url}, 1_000
Page.off(page, :request, listener)
```

Keep listeners short: [one that blocks stalls the
connection](concurrency.md#no-blocking-work-in-listeners).

## Dialogs

Without a listener, `alert`, `confirm` and `prompt` are dismissed. With one, the listener must
accept or dismiss the dialog, or the page waits for it:

```elixir
Page.on(page, :dialog, &Dialog.accept/1)
Page.get_by_role(page, :button, name: "Delete") |> Locator.click!()
```

For a single dialog, `once/3` with what to answer:

```elixir
Page.once(page, :dialog, &Dialog.accept(&1, "42"))
Page.get_by_role(page, :button, name: "Pick a number") |> Locator.click!()
```

## Downloads

With the `download` from `expect_download!` above:

```elixir
Download.suggested_filename(download)
Download.save_as!(download, Path.join(dir, Download.suggested_filename(download)))
```

[`Download.path!/1`](`PlaywrightEx.Download.path!/1`) is the file in a temporary directory, deleted
with the context. Save it to keep it.

## Popups and new pages

A link with `target="_blank"` or a `window.open` opens a popup:

```elixir
popup = Page.expect_popup!(page, fn -> Page.get_by_text(page, "Open terms") |> Locator.click!() end)
Expect.to_have_title!(popup, "Terms")
```

The popup is returned as soon as it opens; actions and `Expect.*` on it wait as usual. For every new page
of a context, opened by any page, listen on the context:

```elixir
BrowserContext.on(context, :page, &send(owner, {:page, &1}))
```

## File choosers

[`Locator.set_input_files!/2`](`PlaywrightEx.Locator.set_input_files!/2`) sets the files of an
`<input type="file">` directly. When the page opens the chooser itself (a styled button that clicks
a hidden input), catch the chooser:

```elixir
chooser = Page.expect_file_chooser!(page, fn -> Page.get_by_text(page, "Upload avatar") |> Locator.click!() end)
FileChooser.set_files!(chooser, %{name: "avatar.png", mimeType: "image/png", buffer: png})
```

## Navigations

`goto`, `reload` and `go_back` wait for the load event. A click that navigates returns before the
next page loads; assert on the new page, which waits for it:

```elixir
Page.get_by_role(page, :link, name: "Settings") |> Locator.click!()
Expect.to_have_url!(page, ~r"/settings$")
```

[`Page.wait_for_url!/3`](`PlaywrightEx.Page.wait_for_url!/3`) waits without asserting,
[`Page.wait_for_load_state!/2`](`PlaywrightEx.Page.wait_for_load_state!/2`) for a load state of the
current page. Avoid `:networkidle` in tests; wait for what the user sees instead.

`to_have_url` and `wait_for_url` take a glob, a `Regex` or a function, which gets the URL as a
`URI` (`URI.parse/1`), as JS gets a `URL`:

```elixir
Page.wait_for_url!(page, &match?(%URI{path: "/authorize"}, &1))
Page.wait_for_url!(page, fn uri -> match?(%{"login_hint" => "john@acme.org"}, URI.decode_query(uri.query || "")) end)
```

More on events: [playwright.dev/python/docs/events](https://playwright.dev/python/docs/events),
[dialogs](https://playwright.dev/python/docs/dialogs),
[downloads](https://playwright.dev/python/docs/downloads),
[navigations](https://playwright.dev/python/docs/navigations).
