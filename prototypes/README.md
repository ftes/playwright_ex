# Restructure prototypes

Four throwaway ports of the official Playwright clients (v1.64) to Elixir, each passing
the same end-to-end scenario (`e2e/reference.mjs`: form, upload, navigation, `expect`,
popup, download). Goal: pick the client to mirror 1:1 so upstream releases can be rolled
by diffing the upstream client. Each prototype annotates ported functions with
`# upstream: <file>:<line>`; see `js/DECISIONS.md` for the OTP mapping.

Run: `cd <client> && mix test` (needs `../node_modules` → `assets/node_modules`).

## Results

| | JS | Python | Java | .NET |
|---|---|---|---|---|
| Statements with direct counterpart | ~85% | ~87% (~70% line-for-line) | ~80% | ~75% |
| Hand-written Elixir LOC | ~2400 (+380 runtime) | ~2640 (+250 shims) | ~1860 (+3840 generated) | ~1870 (+2570 generated) |
| 1.63→1.64 diff inside ported code | ~12 lines, all 1:1 | ~35 lines, all 1:1 | connection hunks 1:1 | mostly 1:1 |
| OTP fit | good (event loop → GenServer) | good (same as JS) | poor (blocking pump, re-entrant handlers deadlock) | ok (C# typing/overload noise) |
| Tracks upstream | is upstream | hand-ports JS, lags | hand-ports JS | hand-ports JS |

All four converged on the same runtime shape: a connection GenServer acting as the event
loop, an ETS heap for mutable object state, `use ChannelOwner` for inheritance, raised
exceptions, and server-side timeouts via call metadata.

## Recommendation

Mirror the JS client (`playwright-core/src/client`, plus `playwright/src/matchers` for
`expect`) by hand, 1:1, and generate the contract around it, as Java/.NET/Python do:

- `api.json` (from `utils/doclint/generateApiJson.js`) → one `@behaviour` per class plus
  option schemas, typespecs and docs. Missing methods fail `--warnings-as-errors`; a
  generated parity report lists the rest.
- `protocol.yml` → typed channel params/results/events (JS `generate_channels.js`,
  .NET `Protocol/Generated`).
- Port the transport 1:1 too.
- Keep the current guid/`{:ok, _}` API as a thin generated compat facade.

Run all code between two `await`s inside the connection's loop process; callers block
only at `await`. The prototypes run it in the caller, which forced a send/register swap
(`js/lib/client/connection.ex:161`) and leaves a check-then-subscribe race
(`js/lib/client/frame.ex:183`). On the loop, upstream's order is safe as-is, because a
process is sequential like the JS event loop. The API name in errors comes from the stack
upstream, but BEAM drops tail-call frames; a `def`-overriding macro sets it at compile time
instead (`js/lib/client/api.ex`), so ported bodies stay unchanged. Look names up in
`api.json` (`waitForURL`, not `waitForUrl`) and pass them along to the loop process.

Open: freeing ETS rows on dispose, a script to re-anchor `# upstream:` line numbers per
release (`dotnet` has `mix playwright.check_upstream --fix`), and `sdkLanguage` (Python's
renders snake_case locators in error messages, closest to Elixir).
