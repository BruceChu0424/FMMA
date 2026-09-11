#!/usr/bin/env python3
"""FMMA shared-memory protocol - the single definition of the memory map.

The HPS program, the CPU program and the testbenches all have to agree on
every word index in the shared on-chip RAM.  Keeping three hand-maintained
copies of that table in C, assembly and Verilog is how a memory map drifts,
so all three are generated from this file instead:

    python protocol.py --emit-c    > fmma_protocol.h        (MarketStream.c)
    python protocol.py --emit-asm  > fmma_protocol.inc      (*.asm)
    python protocol.py --emit-vh   > ../Testbenches/fmma_protocol.vh
    python protocol.py --emit-md                            (docs/07 table)

``make protocol`` regenerates all of them; ``make check-protocol`` fails the
build if a generated file is out of date.

Protocol version 2.  Version 1 was the flat map at words 64-69 with no
sequencing; see docs/07-shared-memory-protocol.md for the migration notes.
"""

from __future__ import annotations

import argparse
import sys

PROTOCOL_VERSION = 2

#: Total size of the shared RAM, in 32-bit words (4 KB on-chip RAM).
MEM_WORDS = 1024

#: Word 0-7 stay zero.  A zero word is the CPU's HALT instruction, so a zeroed
#: region is what parks the CPU safely; word 0 in particular is the address the
#: PC would wrap to if a program ever ran off the end.
RESERVED_BASE = 0
RESERVED_LEN = 8

#: The CPU program is loaded here and the PC powers up pointing at it.
PROGRAM_BASE = 8
PROGRAM_LIMIT = 256          # exclusive; 248 words of program space

#: Inputs: written by the HPS, read by the CPU.
INPUT_BASE = 256
#: Outputs: written by the CPU, read by the HPS.  The HPS never writes here,
#: which is what removes the dual-port write collision that version 1 had.
OUTPUT_BASE = 320

FREE_BASE = 384


class Word:
    __slots__ = ("index", "name", "direction", "summary")

    def __init__(self, index, name, direction, summary):
        self.index = index
        self.name = name
        self.direction = direction       # "in" (HPS->FPGA) or "out" (FPGA->HPS)
        self.summary = summary


# ---------------------------------------------------------------------------
# HPS -> FPGA
# ---------------------------------------------------------------------------

INPUTS = [
    Word(256, "TICK_SEQ", "in",
         "Seqlock counter for the market-data block. The HPS makes it odd "
         "before touching BID/ASK/BID_SIZE/ASK_SIZE and even again afterwards, "
         "so the CPU can tell a consistent snapshot from a half-written one."),
    Word(257, "BID", "in", "Best bid price, in cents (price x FMMA_PRICE_SCALE)."),
    Word(258, "ASK", "in", "Best ask price, in cents (price x FMMA_PRICE_SCALE)."),
    Word(259, "BID_SIZE", "in", "Size resting at the bid, x 10000 (0.0001 lot resolution)."),
    Word(260, "ASK_SIZE", "in", "Size resting at the ask, x 10000 (0.0001 lot resolution)."),
    Word(261, "CFG_THRESH", "in",
         "Mean-reversion trigger distance in price units (cents). "
         "1000 = $10.00."),
    Word(262, "CFG_MAX_POS", "in",
         "Risk limit: the largest absolute inventory the CPU may signal "
         "itself into, in lots."),
    Word(263, "CFG_ENABLE", "in",
         "Master switch. 0 suppresses every signal (the CPU keeps running and "
         "counting rejects); 1 trades normally."),
    Word(264, "CFG_HALF_SPREAD", "in",
         "Quoting strategy: half the spread the CPU quotes around the mid, in "
         "price units."),
    Word(265, "CFG_SKEW", "in",
         "Quoting strategy: how far to shift both quotes per lot of "
         "inventory, in price units. Leaning against the position."),
    Word(266, "CFG_RESTART", "in",
         "Write non-zero to make the CPU jump back to the top of its program: "
         "counters, anchors and the inventory are cleared and the output block "
         "is re-initialised. The CPU clears this word when it acts on it. "
         "There is no reset line from the HPS to the fabric, so this is how "
         "the loader restarts a strategy it has just rewritten. Deliberately "
         "adjacent to FILL_SEQ so the CPU can reach both from one address "
         "register."),
    Word(267, "FILL_SEQ", "in",
         "Publish counter for fill reports. The HPS writes FILL_SIDE and "
         "FILL_QTY first, then increments this."),
    Word(268, "FILL_SIDE", "in", "1 = the HPS bought for us, 2 = it sold."),
    Word(269, "FILL_QTY", "in", "Size of the reported fill, in lots."),
    Word(270, "CFG_POSITION", "in",
         "The inventory the CPU should start from, in lots, signed. Read once "
         "during initialisation and on every CFG_RESTART. Restarting the "
         "strategy must not make the CPU forget a position that really exists "
         "at the broker, or the risk limit would let it double up; the HPS is "
         "the authority on the real position and states it here."),
]

# ---------------------------------------------------------------------------
# FPGA -> HPS
# ---------------------------------------------------------------------------

OUTPUTS = [
    Word(320, "HEARTBEAT", "out",
         "Incremented once per strategy loop. Proof the CPU is alive, and the "
         "basis for measuring the loop rate from the HPS side."),
    Word(321, "SIGNAL", "out", "The trade decision: 1 = buy, 2 = sell."),
    Word(322, "SIGNAL_TICK", "out",
         "The TICK_SEQ value the decision was computed from. Lets the HPS "
         "attribute a signal to the market message that caused it, which is "
         "how end-to-end latency is measured."),
    Word(323, "SIGNAL_SEQ", "out",
         "Incremented after SIGNAL and SIGNAL_TICK are valid. The HPS "
         "edge-detects this word; it never writes it, so no signal can be "
         "lost by a clear that races the CPU."),
    Word(324, "POSITION", "out",
         "Inventory in lots, as a signed 32-bit value. Maintained by the CPU "
         "from the fill reports."),
    Word(325, "STATUS", "out",
         "Bit 0 running, bit 1 market data valid, bit 2 last signal blocked "
         "by the risk limit, bit 3 trading disabled by CFG_ENABLE."),
    Word(326, "REJECTS", "out",
         "Count of decisions the CPU suppressed because of the position "
         "limit or CFG_ENABLE."),
    Word(327, "FW_VERSION", "out",
         "Protocol version the running CPU program implements. The HPS "
         "refuses to trade if this does not match."),
    Word(328, "QUOTE_BID", "out",
         "Quoting strategy: the bid the CPU would show, in cents."),
    Word(329, "QUOTE_ASK", "out",
         "Quoting strategy: the ask the CPU would show, in cents."),
]

ALL_WORDS = INPUTS + OUTPUTS

# ---------------------------------------------------------------------------
# Symbolic values
# ---------------------------------------------------------------------------

SIGNAL_NONE = 0
SIGNAL_BUY = 1
SIGNAL_SELL = 2

FILL_BOUGHT = 1
FILL_SOLD = 2
FILL_SIDE_BOUGHT = FILL_BOUGHT      # long-form aliases
FILL_SIDE_SOLD = FILL_SOLD

STATUS_RUNNING = 1 << 0
STATUS_DATA_VALID = 1 << 1
STATUS_RISK_BLOCKED = 1 << 2
STATUS_DISABLED = 1 << 3

#: Prices and sizes are carried as integers scaled by this factor.
PRICE_SCALE = 100

CONSTANTS = [
    ("FMMA_PROTOCOL_VERSION", PROTOCOL_VERSION, "protocol version implemented here"),
    ("FMMA_MEM_WORDS", MEM_WORDS, "size of the shared RAM in 32-bit words"),
    ("FMMA_PROGRAM_BASE", PROGRAM_BASE, "word address the CPU program loads at"),
    ("FMMA_PROGRAM_LIMIT", PROGRAM_LIMIT, "first word after the program area"),
    ("FMMA_INPUT_BASE", INPUT_BASE, "first HPS -> FPGA word"),
    ("FMMA_OUTPUT_BASE", OUTPUT_BASE, "first FPGA -> HPS word"),
    ("FMMA_PRICE_SCALE", PRICE_SCALE, "fixed-point scale for prices and sizes"),
    ("FMMA_SIGNAL_NONE", SIGNAL_NONE, ""),
    ("FMMA_SIGNAL_BUY", SIGNAL_BUY, ""),
    ("FMMA_SIGNAL_SELL", SIGNAL_SELL, ""),
    ("FMMA_FILL_BOUGHT", FILL_BOUGHT, ""),
    ("FMMA_FILL_SOLD", FILL_SOLD, ""),
    ("FMMA_STATUS_RUNNING", STATUS_RUNNING, ""),
    ("FMMA_STATUS_DATA_VALID", STATUS_DATA_VALID, ""),
    ("FMMA_STATUS_RISK_BLOCKED", STATUS_RISK_BLOCKED, ""),
    ("FMMA_STATUS_DISABLED", STATUS_DISABLED, ""),
]

BANNER = "Generated by Software/protocol.py - do not edit by hand."


def _validate():
    seen = {}
    for w in ALL_WORDS:
        if w.index in seen:
            raise SystemExit(f"duplicate word index {w.index}: "
                             f"{seen[w.index]} and {w.name}")
        seen[w.index] = w.name
        if w.direction == "in" and not (INPUT_BASE <= w.index < OUTPUT_BASE):
            raise SystemExit(f"{w.name} is an input but sits outside the input block")
        if w.direction == "out" and not (OUTPUT_BASE <= w.index < FREE_BASE):
            raise SystemExit(f"{w.name} is an output but sits outside the output block")
        if w.index >= MEM_WORDS:
            raise SystemExit(f"{w.name} at {w.index} is past the end of the RAM")


# ---------------------------------------------------------------------------
# Emitters
# ---------------------------------------------------------------------------

def emit_c():
    out = [
        f"/* {BANNER} */",
        "#ifndef FMMA_PROTOCOL_H",
        "#define FMMA_PROTOCOL_H",
        "",
        "/* Word indices into the shared on-chip RAM. The HPS maps the RAM at",
        " * the lightweight HPS-to-FPGA bridge base and indexes it as a",
        " * volatile unsigned int array, so word N is at byte offset 4*N. */",
        "",
    ]
    for name, value, note in CONSTANTS:
        comment = f"  /* {note} */" if note else ""
        out.append(f"#define {name:<28} {value}u{comment}")
    out.append("")
    out.append("/* HPS -> FPGA */")
    for w in INPUTS:
        out.append(f"#define FMMA_{w.name:<23} {w.index}u")
    out.append("")
    out.append("/* FPGA -> HPS */")
    for w in OUTPUTS:
        out.append(f"#define FMMA_{w.name:<23} {w.index}u")
    out += ["", "#endif /* FMMA_PROTOCOL_H */", ""]
    return "\n".join(out)


def emit_asm():
    out = [
        f"% {BANNER}",
        "% Include from an .asm file with:  .include \"fmma_protocol.inc\"",
        "",
    ]
    for name, value, note in CONSTANTS:
        short = name[len("FMMA_"):] if name.startswith("FMMA_") else name
        comment = f"   % {note}" if note else ""
        out.append(f".equ {short}, {value}{comment}")
    out.append("")
    out.append("% HPS -> FPGA")
    for w in INPUTS:
        out.append(f".equ {w.name}, {w.index}")
    out.append("")
    out.append("% FPGA -> HPS")
    for w in OUTPUTS:
        out.append(f".equ {w.name}, {w.index}")
    out.append("")
    return "\n".join(out)


def emit_vh():
    out = [
        f"// {BANNER}",
        "// Shared-memory word indices for the Verilog testbenches.",
        "`ifndef FMMA_PROTOCOL_VH",
        "`define FMMA_PROTOCOL_VH",
        "",
    ]
    for name, value, note in CONSTANTS:
        comment = f"   // {note}" if note else ""
        out.append(f"`define {name} {value}{comment}")
    out.append("")
    for w in ALL_WORDS:
        out.append(f"`define FMMA_{w.name} {w.index}")
    out += ["", "`endif", ""]
    return "\n".join(out)


def emit_md():
    out = [
        "| Word | Byte offset | Name | Direction | Meaning |",
        "|-----:|------------:|------|-----------|---------|",
        f"| 0-{RESERVED_LEN - 1} | 0x000 | reserved | - | "
        "Must stay zero. A zero word is the CPU's HALT instruction. |",
        f"| {PROGRAM_BASE}-{PROGRAM_LIMIT - 1} | 0x{PROGRAM_BASE * 4:03X} | program | "
        "HPS -> FPGA | CPU program image, written once by the loader. |",
    ]
    for w in ALL_WORDS:
        arrow = "HPS -> FPGA" if w.direction == "in" else "FPGA -> HPS"
        summary = " ".join(w.summary.split())
        out.append(f"| {w.index} | 0x{w.index * 4:03X} | `{w.name}` | {arrow} | {summary} |")
    out.append(f"| {FREE_BASE}-{MEM_WORDS - 1} | 0x{FREE_BASE * 4:03X} | free | - | "
               "Unused; room for an order book. |")
    return "\n".join(out) + "\n"


def main(argv=None):
    _validate()
    p = argparse.ArgumentParser(description="emit the FMMA memory map")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--emit-c", action="store_true")
    g.add_argument("--emit-asm", action="store_true")
    g.add_argument("--emit-vh", action="store_true")
    g.add_argument("--emit-md", action="store_true")
    p.add_argument("-o", "--output", help="write here instead of stdout")
    args = p.parse_args(argv)

    text = (emit_c() if args.emit_c else
            emit_asm() if args.emit_asm else
            emit_vh() if args.emit_vh else
            emit_md())
    if args.output:
        with open(args.output, "w", encoding="ascii", newline="\n") as f:
            f.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
