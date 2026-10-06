# syntax=docker/dockerfile:1
#
# The Photon hub: the assistant, the web UI, and the node binaries it hands
# out to machines it sets up. Deploy it to Fly.io with `fly launch
# --copy-config` (see the README), or run it anywhere:
#
#   docker build -t photon .
#   docker run -p 8080:8080 -v photon-data:/data photon
#
# Stages: self-contained node binaries (Burrito), the hub release, and a slim
# runtime image.

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1-debian-trixie-20260918-slim
ARG RUNTIME_IMAGE=debian:trixie-20260918-slim
ARG TAILSCALE_IMAGE=tailscale/tailscale:stable

FROM ${TAILSCALE_IMAGE} AS tailscale

# --- 1. Self-contained node binaries (mix photon.package) --------------------
# Burrito needs the exact OTP version to have prebuilt runtimes (29.1 does) and
# a specific Zig. Limit the platforms with --build-arg PHOTON_NODE_TARGETS=...
FROM ${ELIXIR_IMAGE} AS nodes
ARG ZIG_VERSION=0.16.0
ARG PHOTON_NODE_TARGETS=linux_x86_64,linux_aarch64,macos_aarch64,macos_x86_64
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates xz-utils \
 && rm -rf /var/lib/apt/lists/*
RUN arch=$(uname -m) \
 && curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/zig-${arch}-linux-${ZIG_VERSION}.tar.xz" \
    | tar -xJ -C /opt \
 && ln -s "/opt/zig-${arch}-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
WORKDIR /build/apps/node
COPY apps/core/mix.exs ../core/
COPY apps/node/mix.exs apps/node/mix.lock ./
RUN mix deps.get
COPY apps/core/lib ../core/lib
COPY apps/node/config config
COPY apps/node/lib lib
RUN mix photon.package --targets "$PHOTON_NODE_TARGETS"

# --- 2. The hub release -------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
WORKDIR /build/apps/hub

COPY apps/core/mix.exs ../core/
COPY apps/node/mix.exs ../node/
COPY apps/hub/mix.exs apps/hub/mix.lock ./
RUN mix deps.get --only prod

# The hub can run a node in its own VM (PHOTON_LOCAL_NODE=true), so it
# carries the node's code too.
COPY apps/core/lib ../core/lib
COPY apps/node/lib ../node/lib
COPY apps/hub/config/config.exs apps/hub/config/prod.exs config/
RUN mix deps.compile

COPY apps/hub/priv priv
COPY apps/hub/lib lib
RUN mix compile

# Assets import LiveView's colocated hooks, which compiling generates.
COPY apps/hub/assets assets
RUN mix assets.setup && mix assets.deploy

COPY apps/hub/config/runtime.exs config/
COPY apps/hub/rel rel
RUN mix release

# --- 3. Runtime ---------------------------------------------------------------
FROM ${RUNTIME_IMAGE}
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates tini \
      openssh-client bash git curl \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen \
 && useradd --system --create-home --home-dir /home/photon --shell /bin/bash photon
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

COPY --from=tailscale /usr/local/bin/tailscaled /usr/local/bin/tailscale /usr/local/bin/
WORKDIR /app
COPY --from=build /build/apps/hub/_build/prod/rel/photon ./
COPY --from=nodes /build/apps/node/dist /app/node-dist

ENV PHOTON_DATA_DIR=/data \
    PHOTON_NODE_DIST=/app/node-dist \
    PORT=8080 \
    RELEASE_DISTRIBUTION=none
EXPOSE 8080
# -s: on Fly, tini isn't PID 1 (Fly's init is), so it registers as a subreaper.
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/app/bin/docker-entrypoint"]
