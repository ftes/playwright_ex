# JS-client port: OTP mapping decisions (baton spike)

Copy of `../js` with the event-loop process replaced by a baton (`lib/runtime/baton.ex`).

Upstream: `packages/playwright-core/src/client/*.ts` (+ `isomorphic/`, `protocol/src/serializers.ts`,
`playwright/src/matchers/`) at v1.64.1. One Elixir module per upstream file/class, same function
order, `# upstream: file:line` on each function, `-- not ported` markers for skipped statements.

| JS | Elixir |
|---|---|
| JS thread | `Runtime.Baton`: one token per driver. Client code runs in the calling process while holding it; `await` releases it. Dispatch runs in an executor process under the token and hands it to each listener (fresh process) until it returns or awaits. |
| mutable object fields | ETS rows (one public table per connection). `this._x` → `get(this, :_x)`, `this._x = v` → `put(this, :_x, v)`; `Set`/`Map` helpers. Reads are lock-free, writes happen under the baton. |
| ChannelOwner instance | `%Page{guid, conn}` handle. Field names keep their JS spelling (`:_mainFrame`). |
| class without mutation (Locator, Download) | Plain immutable struct with JS field names (`locator._selector`). |
| `extends` / `super(...)` | `use ChannelOwner` (defdelegate + defoverridable); `ChannelOwner.new(__MODULE__, ...)`. Virtual calls via `this.__struct__.on(...)`. |
| `this._channel.foo(p, o)` | `channel_call(this, :foo, p, o)`. Channel refs become handles in `Connection._from_wire` (stands in for the generated validators). |
| `this._channel.on(...)` | `EventEmitter.on(_channel(this), ...)`; listeners are closures, handed the baton in `emit`. |
| `async` fn + `await` | Blocking function in the caller process. `await p` → `Promise.await(p)` (GenServer.call answered when the promise settles). |
| promise not awaited immediately | `Promise.async(fn -> ... end)` returns after the body reaches its first await, matching JS semantics (listener registered before the caller's next statement). |
| `new Promise(executor)` / `.then` / `Promise.race` / `Promise.all` | Heap promises (`Runtime.Promise`); reactions run synchronously in the settling holder, awaiters resume before the next macrotask. |
| `setTimeout` | `Process.send_after` to the baton server (macrotask). |
| AsyncLocalStorage zones | Process dictionary (`Runtime.Zones`). |
| `throw` / `try/catch` / `instanceof` | `raise` / `rescue` / struct matches (`Errors.is_playwright_error/1` flattens the class hierarchy). |
| `e.message = ...` | `Errors.rewrite_error_message/2` returns a new exception. |
| stack-derived apiName | `Api.def` records the public entry point, because BEAM drops tail-call frames. |
| `undefined` / `null` | `nil` / `:null`. |

Known gaps: heap objects that are not channel owners (Waiter, Promise) are never freed. A
callback that blocks on non-Playwright work while holding the baton stalls the driver (as in
JS). `update(obj, field, fun)` must not await inside `fun` (hoist the awaited call).
