#!/usr/bin/env bash
#
# FMMA regression suite.
#
# Runs everything that can be checked without the board:
#   1. the Python toolchain and strategy tests (ISA, assembler, simulator)
#   2. the ALU equivalence test   (RTL vs the golden model, ~9500 vectors)
#   3. the full-chain testbench   (real top level vs a behavioural Qsys system)
#
# Exits non-zero if anything fails, so it can gate a commit or run in CI.
#
#   ./run_sim.sh            run everything
#   ./run_sim.sh --quick    skip the Verilog stages
#
# Requirements: python3, and Icarus Verilog on PATH (the Windows installer
# puts it in C:\iverilog\bin, which this script adds automatically).

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOFTWARE="$HERE/../Software"
BUILD="$HERE/build"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

# Icarus is not on PATH by default after the winget install.
for candidate in /c/iverilog/bin "/c/Program Files/iverilog/bin"; do
    [ -d "$candidate" ] && PATH="$candidate:$PATH"
done
export PATH

PYTHON="${PYTHON:-python}"
command -v python3 >/dev/null 2>&1 && PYTHON="${PYTHON_OVERRIDE:-python3}"

pass=0
fail=0
skipped=0

banner() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
ok()     { printf '   \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass + 1)); }
bad()    { printf '   \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail + 1)); }
skip()   { printf '   \033[33mSKIP\033[0m %s\n' "$1"; skipped=$((skipped + 1)); }

RTL="$SOFTWARE/HFTtop.v \
     $HERE/../Code/PC.v $HERE/../Code/IR $HERE/../Code/FR \
     $HERE/../Code/registerFinal $HERE/../Code/MUX16to1 $HERE/../Code/MUX2to1 \
     $HERE/../Code/ALUFinal $HERE/../Code/FSMTrial $HERE/../Code/disp \
     $HERE/../Code/Encoder4to16 $HERE/../Code/decoder.v"

mkdir -p "$BUILD"

# ---------------------------------------------------------------- stage 1
banner "Regenerating the memory map and the program"
( cd "$SOFTWARE" \
  && "$PYTHON" protocol.py --emit-c   -o fmma_protocol.h \
  && "$PYTHON" protocol.py --emit-asm -o fmma_protocol.inc \
  && "$PYTHON" protocol.py --emit-vh  -o "$HERE/fmma_protocol.vh" \
  && "$PYTHON" Assembler.py trading.asm --quiet \
  && "$PYTHON" gen_alu_vectors.py >/dev/null ) \
  && ok "generated sources are current" \
  || { bad "could not regenerate the generated sources"; exit 1; }

# ---------------------------------------------------------------- stage 2
banner "Python: ISA, assembler, simulator, strategy"
if ( cd "$SOFTWARE" && "$PYTHON" -m unittest test_toolchain test_strategy 2>&1 \
     | tail -20 ); then
    ok "python unit tests"
else
    bad "python unit tests"
fi

if [ "$QUICK" = "1" ]; then
    banner "Summary"
    printf '   %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

# ---------------------------------------------------------------- stage 3
if ! command -v iverilog >/dev/null 2>&1; then
    banner "Verilog simulation"
    skip "iverilog is not installed (winget install Icarus.Verilog)"
    banner "Summary"
    printf '   %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
    [ "$fail" -eq 0 ] || exit 1
    exit 0
fi

banner "RTL: ALU equivalence against the golden model"
if iverilog -g2005 -o "$BUILD/tb_alu.vvp" "$HERE/../Code/ALUFinal" \
        "$HERE/tb_alu.v" 2>"$BUILD/tb_alu.log"; then
    if ( cd "$HERE" && vvp "$BUILD/tb_alu.vvp" ) 2>&1 | tee -a "$BUILD/tb_alu.log" \
         | grep -q "tb_alu PASSED"; then
        ok "tb_alu"
    else
        bad "tb_alu (see $BUILD/tb_alu.log)"
    fi
else
    bad "tb_alu did not compile (see $BUILD/tb_alu.log)"
fi

banner "RTL: full chain, HPS protocol against the real top level"
# shellcheck disable=SC2086
if iverilog -g2005 -I"$HERE" -o "$BUILD/tb_fmma.vvp" $RTL \
        "$HERE/HPSfgpa2_stub.v" "$HERE/tb_fmma.v" 2>"$BUILD/tb_fmma.log"; then
    if ( cd "$HERE" && vvp "$BUILD/tb_fmma.vvp" ) 2>&1 | tee -a "$BUILD/tb_fmma.log" \
         | grep -q "tb_fmma PASSED"; then
        ok "tb_fmma"
    else
        bad "tb_fmma (see $BUILD/tb_fmma.log)"
    fi
else
    bad "tb_fmma did not compile (see $BUILD/tb_fmma.log)"
fi

banner "RTL: latency budget"
# shellcheck disable=SC2086
if iverilog -g2005 -I"$HERE" -o "$BUILD/tb_latency.vvp" $RTL \
        "$HERE/HPSfgpa2_stub.v" "$HERE/tb_latency.v" 2>"$BUILD/tb_latency.log"; then
    if ( cd "$HERE" && vvp "$BUILD/tb_latency.vvp" ) 2>&1 \
         | tee -a "$BUILD/tb_latency.log" | grep -q "tb_latency PASSED"; then
        ok "tb_latency"
        grep -E "cycles = " "$BUILD/tb_latency.log" | sed 's/^/     /'
    else
        bad "tb_latency (see $BUILD/tb_latency.log)"
    fi
else
    bad "tb_latency did not compile (see $BUILD/tb_latency.log)"
fi

# ---------------------------------------------------------------- summary
banner "Summary"
printf '   %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skipped"
if [ "$fail" -eq 0 ]; then
    printf '   \033[32mall green\033[0m\n'
    exit 0
fi
exit 1
