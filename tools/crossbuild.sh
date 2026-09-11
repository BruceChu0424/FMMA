#!/bin/sh
#
# Cross-build the HPS application for the DE1-SoC.
#
# The board cannot build marketstream itself: its image ships libssl.so
# without the headers, and its Ubuntu 12.04 archives are gone, so there
# is no way to install them.  This produces a static armhf binary that
# runs on it anyway.  See tools/Dockerfile.armhf for why static.
#
#   tools/crossbuild.sh              build marketstream, fmma-probe, fmma-bench
#   tools/crossbuild.sh clean
#
# The result lands in Software/ alongside the sources.  Verify it with
#
#   file Software/marketstream
#   -> ELF 32-bit LSB executable, ARM, EABI5, statically linked
#
set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=fmma-armhf
TARGET=${1:-static}

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building the cross-compiler image (first run only, a few minutes)"
    docker build -t "$IMAGE" -f "$REPO/tools/Dockerfile.armhf" "$REPO/tools"
fi

echo "cross-building: make $TARGET"
docker run --rm -v "$REPO:/src" -w /src/Software "$IMAGE" \
       make "$TARGET" CC=arm-linux-gnueabihf-gcc

if [ "$TARGET" != "clean" ]; then
    echo
    for f in marketstream fmma-probe fmma-bench; do
        [ -f "$REPO/Software/$f" ] && file "$REPO/Software/$f" 2>/dev/null \
            || ls -l "$REPO/Software/$f" 2>/dev/null || true
    done
fi
