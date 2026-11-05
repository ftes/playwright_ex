# Linux image like CI's test job (.github/workflows/elixir.yml). `run setup` passes the Elixir and
# OTP versions from .tool-versions; the driver, browsers and their system deps are installed in the
# container by `mix playwright_ex.install -- <browsers> --with-deps`, as CI does.
ARG ELIXIR
ARG OTP
ARG OS=ubuntu-resolute-20261024.1
FROM hexpm/elixir:${ELIXIR}-erlang-${OTP}-${OS}
# `+JMsingle true` under amd64 emulation on Apple silicon: the JIT's dual-mapped code fails there.
ARG ERL_FLAGS=""
ENV ERL_FLAGS=$ERL_FLAGS
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      git xvfb xauth ca-certificates rsync procps && rm -rf /var/lib/apt/lists/*
RUN mix local.hex --force && mix local.rebar --force
ENV MIX_ENV=test CI=true LANG=C.UTF-8 PLAYWRIGHT_EX_CACHE_DIR=/cache
WORKDIR /app
