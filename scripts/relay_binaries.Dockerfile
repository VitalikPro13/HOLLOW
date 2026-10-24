# Build environment for the prebuilt relay and media forwarder
# (scripts/build_relay_binaries.sh). Ubuntu 22.04 sets the glibc floor at 2.35,
# so the binaries run on Ubuntu 22.04 and 24.04 and Debian 12 and 13. aarch64 is
# cross-compiled against the arm64 builds of the same distro libraries.
# ubuntu:22.04 as of 2026-10-02, pinned so a rebuild cannot pick up another base.
FROM ubuntu:22.04@sha256:0a9887931b0e38af2e3487ed39e29436b0535c4f3f52e57745baaf79d1898956

ARG RUST_VERSION=1.95.0
# rustup-init 1.29.2 for x86_64 Linux, checked against this hash before it runs.
ARG RUSTUP_VERSION=1.29.2
ARG RUSTUP_SHA256=5be191e8c70a5007074254cb74d78dbfdd25cd5a61c27de7b8e5410122ec24f4
ENV DEBIAN_FRONTEND=noninteractive

# The default sources serve amd64 only; arm64 comes from ports.ubuntu.com.
RUN sed -i 's/^deb /deb [arch=amd64] /' /etc/apt/sources.list \
    && printf '%s\n' \
        'deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports jammy main universe' \
        'deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports jammy-updates main universe' \
        'deb [arch=arm64] http://ports.ubuntu.com/ubuntu-ports jammy-security main universe' \
        > /etc/apt/sources.list.d/arm64.list \
    && dpkg --add-architecture arm64 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential cmake pkg-config curl ca-certificates file binutils \
        libssl-dev libsodium-dev zlib1g-dev \
        gcc-aarch64-linux-gnu g++-aarch64-linux-gnu binutils-aarch64-linux-gnu libc6-dev-arm64-cross \
        libssl-dev:arm64 libsodium-dev:arm64 zlib1g-dev:arm64 \
    && rm -rf /var/lib/apt/lists/*

ENV RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo PATH=/opt/cargo/bin:$PATH
RUN curl --proto '=https' --tlsv1.2 -sSf -o /tmp/rustup-init \
        "https://static.rust-lang.org/rustup/archive/$RUSTUP_VERSION/x86_64-unknown-linux-gnu/rustup-init" \
    && echo "$RUSTUP_SHA256  /tmp/rustup-init" | sha256sum -c - \
    && chmod +x /tmp/rustup-init \
    && /tmp/rustup-init -y --profile minimal --default-toolchain "$RUST_VERSION" --no-modify-path \
    && rm /tmp/rustup-init \
    && rustup target add aarch64-unknown-linux-gnu \
    && chmod -R a+rwX /opt/cargo /opt/rustup
