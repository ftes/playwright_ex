# Linux test container

Manual tooling (not run by CI, `mix test` or any alias) for failures that only show on CI's
Linux runners, and for flake rates under load. The image matches CI's test job: Elixir/OTP from
`.tool-versions`, xvfb, the driver and browsers installed by
`mix playwright_ex.install -- <browsers> --with-deps`.

The checkout (default: this repo; `-C <path>` for another, e.g. a jj workspace) is rsynced into a
long-lived container on each command; its `_build` and `deps` stay in the container.

## Quick start

```sh
scripts/linux/run setup chromium                     # once (again after changing .tool-versions)
scripts/linux/run test test/upstream/page/workers_test.exs
CPUS=2 scripts/linux/run stress 6 test/upstream/page/workers_test.exs --repeat-until-failure 20
```

## Commands

- `setup [browsers...]`: build the image, (re)create the container, install driver and browsers.
- `test [mix test args...]`: `xvfb-run mix test <args>`, as CI.
- `exec <shell command>`: any command in the synced checkout.
- `stress <copies> [mix test args...]`: that many parallel `mix test` runs; logs in `tmp/linux/`.
  `CPUS=2` limits the container to CI's 2 cores.
- `node <script.js> [args...]`: a plain Node script against the driver's bundled `playwright-core`
  (`require(process.env.PW_CORE)`), to check whether upstream's client behaves the same; example:
  `scripts/linux/run node scripts/linux/js/worker_iframe.js 20`.

`PLATFORM=linux/amd64` is CI's architecture (emulated on Apple silicon: slow, with
`+JMsingle true` for the JIT); the default is the host's architecture (native, fast). Each platform
has its own container, `playwright_ex-linux-<arch>`. The host's upstream source cache
(`~/Library/Caches/playwright_ex` or `~/.cache/playwright_ex`) is mounted read-only, as the
upstream download's tar extraction fails under emulation. `BROWSER`, `DEBUG` (e.g.
`pw:protocol`) and the variables named in `PASS_ENV` are forwarded.
