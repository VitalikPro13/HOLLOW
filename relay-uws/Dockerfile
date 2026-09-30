FROM debian:bookworm-slim AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake g++ make \
    libssl-dev libsodium-dev zlib1g-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY CMakeLists.txt ./
COPY src/ src/
COPY uWebSockets/ uWebSockets/
COPY uSockets/ uSockets/

RUN mkdir build && cd build \
    && cmake .. -DCMAKE_BUILD_TYPE=Release \
    && make -j$(nproc)

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libssl3 libsodium23 zlib1g ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/hollow-relay /usr/local/bin/hollow-relay

# An unprivileged account holding no capability at all: the compose file lets it
# bind 443 inside the container's own network namespace, so a relay compromise
# has nothing to use against the container or the host.
RUN groupadd --system --gid 999 hollow \
    && useradd --system --uid 999 --gid 999 --no-create-home --shell /usr/sbin/nologin hollow

# Docker copies this directory's ownership onto an empty named volume
# mounted here, which is the only way the unprivileged process can write
# its report counts and their key.
RUN mkdir -p /data && chown 999:999 /data

EXPOSE 443

USER hollow

ENTRYPOINT ["hollow-relay"]
