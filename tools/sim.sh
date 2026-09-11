#!/bin/sh
#
# Run the whole verification suite in a container.
#
# Testbenches/run_sim.sh needs Icarus Verilog and Python 3.  On Linux
# both are one apt-get away; on Windows, where this project is
# developed, neither is.  Quartus bundles Questa, but the starter
# edition wants a licence file a fresh machine will not have, and there
# is no iverilog package in winget.
#
#   tools/sim.sh              everything: Python + RTL
#   tools/sim.sh --quick      Python only
#
# Run run_sim.sh directly instead if you already have the tools.
set -e

REPO=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=fmma-sim

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "building the simulation image (first run only)"
    docker build -t "$IMAGE" -f "$REPO/tools/Dockerfile.sim" "$REPO/tools"
fi

exec docker run --rm -v "$REPO:/src" -w /src/Testbenches "$IMAGE" \
     ./run_sim.sh "$@"
