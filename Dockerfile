# syntax=docker/dockerfile:1
#
# The Photon hub: GUI, session history, and the node binaries it hands out to
# machines it sets up. Deploy it to Fly.io with `fly launch --copy-config` (see
# the README), or run it anywhere:
#
#   docker build -t photon .
#   docker run -p 8080:8080 -v photon-data:/data photon
#
# Stages: unreal-agent-runner for every platform (Go), self-contained node
# binaries (Burrito), the hub release, and a slim runtime image.

ARG ELIXIR_IMAGE=hexpm/elixir:1.20.4-erlang-29.1-debian-trixie-20260918-slim
ARG RUNTIME_IMAGE=debian:trixie-20260918-slim
ARG GO_IMAGE=golang:1.27.1-trixie
ARG TAILSCALE_IMAGE=tailscale/tailscale:stable

FROM ${TAILSCALE_IMAGE} AS tailscale

# --- 1. unreal-agent-runner, static, for each node platform -----------------
FROM ${GO_IMAGE} AS runners
ARG UNREAL_AGENT_REPO=https://github.com/unreallabsai/unreal-agent
ARG UNREAL_AGENT_REF=origin/HEAD
WORKDIR /src
RUN git clone --filter=blob:none "$UNREAL_AGENT_REPO" . && git checkout --detach "$UNREAL_AGENT_REF"
RUN set -eu; \
    for spec in linux_x86_64:linux:amd64 linux_aarch64:linux:arm64 \
                macos_aarch64:darwin:arm64 macos_x86_64:darwin:amd64; do \
      name=${spec%%:*}; platform=${spec#*:}; \
      CGO_ENABLED=0 GOOS=${platform%%:*} GOARCH=${platform#*:} \
        go build -trimpath -buildvcs=false \
          -o "/runners/$name/unreal-agent-runner" ./cmd/unreal-agent-runner; \
    done

# --- 2. Self-contained node binaries (mix photon.package) --------------------
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
WORKDIR /build/node
RUN mix local.hex --force && mix local.rebar --force
COPY node/mix.exs node/mix.lock ./
RUN mix deps.get
COPY node/config config
COPY node/lib lib
COPY --from=runners /runners _build/runners
RUN mix photon.package --prebuilt-runners --targets "$PHOTON_NODE_TARGETS"

# --- 3. The hub release -------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS build
ARG TARGETARCH
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*
ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY node/mix.exs node/
RUN mix deps.get --only prod

# The embedded node (off on Fly; PHOTON_LOCAL_NODE=true enables it) runs the
# runner for this image's own platform.
COPY node/lib node/lib
COPY --from=runners /runners /tmp/runners
RUN case "${TARGETARCH:-amd64}" in arm64) t=linux_aarch64 ;; *) t=linux_x86_64 ;; esac \
 && mkdir -p node/priv/bin \
 && cp "/tmp/runners/$t/unreal-agent-runner" node/priv/bin/

COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY priv priv
COPY lib lib
RUN mix compile

# Assets import LiveView's colocated hooks, which compiling generates.
COPY assets assets
RUN mix assets.setup && mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# --- 4. Runtime ---------------------------------------------------------------
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
COPY --from=build /app/_build/prod/rel/photon ./
COPY --from=nodes /build/node/dist /app/node-dist

ENV PHOTON_DATA_DIR=/data \
    PHOTON_NODE_DIST=/app/node-dist \
    PORT=8080 \
    RELEASE_DISTRIBUTION=none
EXPOSE 8080
# -s: on Fly, tini isn't PID 1 (Fly's init is), so it registers as a subreaper.
ENTRYPOINT ["/usr/bin/tini", "-s", "--", "/app/bin/docker-entrypoint"]
