# ClusterFuzzLite's build image for the relay fuzz targets (relay-uws/fuzz). Only the
# relay's crypto (libsodium, OpenSSL) is needed; the targets link it statically
# because the image that runs them has neither. Dormant: no workflow runs it, since a
# public repo's workflow artifacts would publish every crash input; the fuzzers run
# nightly on the Mac mini instead (relay-uws/fuzz/nightly.sh).
FROM gcr.io/oss-fuzz-base/base-builder:v1@sha256:1f9cf74bc3d7029b528494542f9d9851b256dceed38d3f420989434dc5ae0760
RUN apt-get update && apt-get install -y --no-install-recommends libsodium-dev libssl-dev
COPY . $SRC/hollow
WORKDIR $SRC/hollow
COPY .clusterfuzzlite/build.sh $SRC/
