# Options, devices and projects

Playwright Test's `use` options are options at five levels here, each over the one before per
option: the config, a project, the module, a describe block and the test. A call's own options
win over all of them. The rules (which level takes which option, `nil`, how the layers merge) are
in `Playwright.Test`'s [Context defaults](Playwright.Test.html#module-context-defaults) and
[Browser](Playwright.Test.html#module-browser); this guide shows each level. Snippets alias
`Playwright.{Browser, BrowserContext, Page, Test}` and `Playwright.Test.BrowserPool`.

| Playwright Test | Here |
|---|---|
| `use: { locale: 'de-DE' }` in the config | `config :playwright, :test, locale: "de-DE"` |
| a project's `use` | `parameterize: [Playwright.Test.parameters(locale: "de-DE")]` |
| `test.use({ locale: 'de-DE' })` at a file's top | `use Playwright.Case, locale: "de-DE"` |
| `test.use({ ... })` in a `test.describe` | `@describetag Test.use(locale: "de-DE")` |
| (a describe around one test) | `@tag Test.use(locale: "de-DE")` |
| `...devices['iPhone 13']` | `Playwright.device("iPhone 13")` as the options |

The context options are options of their own, with `Playwright.Browser.new_context/2`'s names
(`locale`, `viewport`, `color_scheme`, `timezone_id`, `base_url`, `storage_state`, ...), and
`context_options` is Playwright Test's `contextOptions`, for any other option of `new_context`
(`record_har`, `strict_selectors`). The values are known at compile time, not functions. The
config's, the project's and the module's options reach every context the module creates,
`setup_all`'s included (`goto("/")` works there with `base_url`); a describe's and a test's reach
that test's contexts, as ExUnit runs `setup_all` without them.

A library that passes options in a call merges into the test's resolved ones,
`Playwright.Test.info().use`, as the call's replace them as a whole (`extra_http_headers` too):
`Browser.new_context!(browser, extra_http_headers: Map.merge(Test.info().use[:extra_http_headers]
|| %{}, headers))`.

## Devices

Playwright Test's `devices['iPhone 13']` is `Playwright.device("iPhone 13")`: the device's
context options as a keyword list, static data of the pinned Playwright version, so it needs no
driver and works at compile time. An unknown name raises, naming the closest;
`Playwright.devices/0` is the map of all of them, and its docs list the names.
`Browser.new_context!/2` takes a device as it is or with more. Playwright Test's
`{ ...devices['iPhone 13'], locale: 'de-DE' }` is `Keyword.merge/2`, whose later options
override the device's:

```elixir
test "on a phone" do
  browser = BrowserPool.browser(browser_name: :webkit)
  iphone = Playwright.device("iPhone 13")
  page = BrowserContext.new_page!(Browser.new_context!(browser, Keyword.merge(iphone, locale: "de-DE")))
  # ...
end
```

The device's options are the call's, so they win over Playwright Test's defaults (its viewport
over the 1280x720 one), and its `default_browser_type` (`"webkit"`) names its browser, which
`new_context` ignores.

For a module, Playwright Test's `test.use({ ...devices['iPhone 13'] })` at a file's top, give the
device to a `use Playwright.Test` (a module's `use`s add up; in one `use`, it is
`use Playwright.Case, [async: true] ++ Playwright.device("iPhone 13")`; `++` is only for keys
the device doesn't have, as a duplicated option raises):

```elixir
defmodule MyApp.PhoneTest do
  use Playwright.Case, async: true
  use Playwright.Test, Playwright.device("iPhone 13")

  test "on a phone", %{page: page} do
    # ...
  end
end
```

As in Playwright Test, the device also picks the browser: without a `browser_name` in the
module's `use`, its project or the config, `BrowserPool.browser/1` (so `Playwright.Case`'s
`browser`) launches the device's `default_browser_type`, WebKit here. A `browser_name` set in
any of those wins (`use Playwright.Case, browser_name: :chromium`). `Playwright.Case` puts the
browser's name in the context, `%{browser_name: :webkit}` here.

For the whole suite (one project), the device goes in the config. `config/config.exs` and
`config/test.exs` are evaluated before the dependencies are compiled, so `Playwright.device/1`
can't be called there: write the options out, or set them in `config/runtime.exs`, which runs
after the compilation (the runner reads the config at run time). Guard it with `config_env()`: the
dependency is `only: [:dev, :test]`, so `Playwright.device/1` fails in every other env:

```elixir
# config/runtime.exs
if config_env() == :test do
  config :playwright, :test, Playwright.device("Desktop Chrome")
end
```

## Describe blocks and tests

For a describe block, Playwright Test's `test.use` in a `test.describe`, tag it with
`Playwright.Test.use/1`, which takes the options a describe may set: the context options,
`context_options`, `action_timeout`, `navigation_timeout`, `trace`, `screenshot` and `video`:

```elixir
describe "in Berlin" do
  @describetag Test.use(timezone_id: "Europe/Berlin", locale: "de-DE")

  test "shows local time", %{page: page} do
    # ...
  end
end
```

For one test, `@tag` it. Playwright Test has no `test.use` for a single test, and nests a
describe around it instead; ExUnit's describe blocks can't nest:

```elixir
@tag Test.use(color_scheme: :dark, trace: :on)
test "is readable in the dark", %{page: page} do
  # ...
end
```

To run one test per device, generate them, as Playwright Test's loop over `test.describe`
blocks with a `test.use`:

```elixir
for name <- ["iPhone 13", "Pixel 7"] do
  @tag Test.use(Playwright.device(name))
  test "the menu collapses on #{name}", %{page: page} do
    # ...
  end
end
```

The browser is the module's, as in Playwright Test, where a describe with another one starts a
new worker: `Test.use(browser_name: _)` raises, and a tag's device doesn't switch the browser.
Plain tags named like options (`@tag trace: :on`) set nothing: only `Test.use/1`'s keys are read.

## Projects

Playwright Test's `projects: [{ use: { ...devices['Desktop Chrome'] } }, ...]`, one run per
browser and device, are ExUnit's `parameterize:` with a `Playwright.Test.parameters/1` map per
project. It takes `Test.use/1`'s options, the worker's (`browser_name`, `launch_options`,
`connect_options`) and the project's `name`:

```elixir
defmodule MyApp.Projects do
  # `PROJECTS="Desktop Firefox" mix test` runs one.
  def all do
    names = String.split(System.get_env("PROJECTS", "Desktop Chrome,Desktop Firefox,Desktop Safari"), ",")
    for name <- names, do: Playwright.Test.parameters([name: name] ++ Playwright.device(name))
  end
end

defmodule MyApp.SignUpTest do
  use Playwright.Case, async: true, parameterize: MyApp.Projects.all()

  test "signs up", %{page: page} do
    # ...
  end
end
```

The project's options are over the config's and under the module's `use`, for every context of
the module's run, `setup_all`'s included, and its device picks the browser as above: Chromium,
Firefox and WebKit here (not with a `browser_name` in the config, which wins over a device:
give the projects one, `Test.parameters(browser_name: :firefox)`). A module adds its own options
over the project's (`use Playwright.Case, parameterize: MyApp.Projects.all(), locale: "de-DE"`),
and parameters of your own go next to them: `Map.put(Test.parameters(...), :role, :admin)`. The
`name` is upstream's `project.name`: a failure prints it as ExUnit's parameters, the
GitHub annotations of `Playwright.Test.GitHubFormatter` show it (`[de] › ...`), and it fills a
snapshot template's `{projectName}`. Without one, the failure and the annotations show the
project's browser (its `browser_name`, else its device's `default_browser_type`), and
`{projectName}` is empty, so name projects that share a browser, as two locales do:
`Test.parameters([name: "de", locale: "de-DE"] ++ Playwright.device("Desktop Chrome"))` fails as
`Parameters: %{"playwright.project": #Playwright.Test.Project<"de">}`. ExUnit's filters don't see
`parameterize:` values, so to run one project, read an env var where the list is built, as above.

## Your own case template

To add setup after the page's, use `Playwright.Case` in your template's `using` and put the
setup after it there; a template's own `setup` runs before the ones its `using` brings in:

```elixir
# test/support/browser_case.ex
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      use Playwright.Case

      setup %{context: context} do
        Playwright.BrowserContext.set_default_timeout(context, 5_000)
        :ok
      end
    end
  end
end
```

A template forwards its options from `using opts` as they are: a module's `use`s merge per key,
the later winning, and ExUnit.Case's keys are ignored. So its own `use Playwright.Test, ...`
lines come before the forwarded options, which go last; else the template's options (a device's
viewport, say) override the test module's, the reverse of Playwright Test, where the file's
`test.use` beats the project's device. Options of the template's own are unknown to `use
Playwright.Test` and raise: pop them before forwarding the rest.

```elixir
using opts do
  {sandbox, opts} = Keyword.pop(opts, :sandbox, true)

  quote do
    use Playwright.Test, Playwright.device("iPhone 13")
    use Playwright.Case, unquote(opts)
    @moduletag sandbox: unquote(sandbox)
  end
end
```

To change a piece, say another browser, write the template from the pieces. Its own `setup`
runs before those of its `using`, so make `use Playwright.Test` the first line of its body: the
test is then registered before the template's `setup` creates a context (a context created
before the registration makes it raise, saying so). That `use` takes no options: they go in
`using`.

```elixir
defmodule MyApp.BrowserCase do
  use ExUnit.CaseTemplate
  use Playwright.Test

  alias Playwright.{Browser, BrowserContext}
  alias Playwright.Test.BrowserPool

  using do
    quote do
      use Playwright.Test
      alias Playwright.{Browser, BrowserContext, Expect, Locator, Page, Test}
    end
  end

  setup_all do
    %{browser: BrowserPool.browser()}
  end

  # `@tag Test.use(locale: "de-DE")` on a test sets its options.
  setup %{browser: browser} do
    context = Browser.new_context!(browser)
    %{context: context, page: BrowserContext.new_page!(context)}
  end
end
```

## The running test

`Playwright.Test.info/0` is Playwright Test's `test.info()`: the running test's `test_pid`,
`file`, `test_name`, `output_dir`, `timeout`, `deadline` and its resolved options, `use`, in the
test's process and in processes with it in `$callers` (a `Task`, a route handler). A library
that owns resources per test (an Ecto sandbox owner, a session) finds the test from a `Task` with
it: `Playwright.Test.info().test_pid`. In the module's `setup_all`, `info/0` returns the module's
fields (`file`, `timeout`, `use`); elsewhere it raises, also in `on_exit` callbacks, where
`Playwright.Test.info(test_pid)` has the test's result. A library that also runs outside them
reads the config there:

```elixir
use = if Test.in_registered_scope?(), do: Test.info().use, else: Test.config()
use[:base_url]
```

The config has another shape (see `Playwright.Test.info/0`), so read the keys both have with Access: `use[:base_url]` is `nil` when unset, where
`use.base_url` raises.
