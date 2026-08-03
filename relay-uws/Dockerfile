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
    libssl3 libsodium23 zlib1g ca-certificates libcap2-bin \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/build/hollow-relay /usr/local/bin/hollow-relay

# Bind :443 without running as root. The capability rides the binary (the same
# setcap the systemd deployment uses), so the process drops to an unprivileged
# account and a relay compromise does not hand over the container.
RUN setcap cap_net_bind_service=+ep /usr/local/bin/hollow-relay \
    && useradd --system --no-create-home --shell /usr/sbin/nologin hollow

EXPOSE 443

USER hollow

ENTRYPOINT ["hollow-relay"]
