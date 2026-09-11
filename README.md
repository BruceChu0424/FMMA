# FMMA — FPGA Market Maker Accelerator

A low-latency trading system on the Terasic DE1-SoC. A custom 32-bit RISC
CPU in the Cyclone V fabric makes the trading decisions; the ARM Cortex-A9
on the same die does the networking. Live quotes from Coinbase go in, paper
orders to Alpaca come out, and the decision in between takes **3.9 µs,
deterministically**.

ECE 4900 senior design, Utah State University — group 20.
Built on the 32-bit CPU designed in ECE 3710 by group 1011.

```
   Coinbase ticker (TLS/WebSocket)                Alpaca paper trading
            │                                              ▲
            ▼                                              │ POST /v2/orders
  ┌───────────────── HPS: ARM Cortex-A9, Linux ────────────┴──────────┐
  │  MarketStream.c                                                   │
  │    parse "97431.02" -> 9743102   (exact integers, no float)       │
  │    publish through a seqlock, poll SIGNAL_SEQ for an edge         │
  │    execute, check the status, report the fill back                │
  └───────────────┬──────────────────────────────────▲────────────────┘
                  │  lightweight AXI bridge, 0xFF200000, 50 MHz
  ┌───────────────▼──────────────────────────────────┴────────────────┐
  │            4 KB dual-port on-chip RAM  (the contract)             │
  │   0-7 reserved │ 8-255 program │ 256+ inputs │ 320+ outputs       │
  └───────────────▲──────────────────────────────────┬────────────────┘
                  │  port s2: fetch / load / store   │
  ┌───────────────┴──────────────────────────────────▼────────────────┐
  │  Custom 32-bit RISC CPU running trading.asm                       │
  │    16 registers · 3 cycles per instruction · 780 ns loop          │
  │    mean-reversion strategy + position limits, enforced in fabric  │
  └───────────────────────────────────────────────────────────────────┘
```

## Status

| | |
|---|---|
| Simulation | **green** — 82 Python tests, ~9,500 ALU equivalence vectors, 31 full-chain RTL assertions, all in 25 s |
| FPGA build | **timing closed** at 50 MHz — see [docs/13](docs/13-test-report.md) |
| Host program | **builds clean** under `-Wall -Wextra`, links against OpenSSL |
| On board | **outstanding** — [docs/11](docs/11-board-bringup.md) is the procedure |

## Start here

* **[docs/](docs/README.md)** — the engineering record, 18 documents
* **[docs/07-shared-memory-protocol.md](docs/07-shared-memory-protocol.md)** — the HPS↔FPGA contract, and the most important thing to read
* **[docs/11-board-bringup.md](docs/11-board-bringup.md)** — bare board to running demo
* **[CHANGELOG.md](CHANGELOG.md)** — what changed and why

## Quick start

### Run the tests (no hardware needed)

```bash
Testbenches/run_sim.sh
```

About 25 seconds. Prints `all green`, and the measured latency figures.

### Build the FPGA image

```bash
quartus_sh --flow compile HFTTop        # about an hour
quartus_pgm -m jtag -o "p;output_files/HFTTop.sof"
```

`HEX0` should then show a steady `8` — the CPU is parked at its entry word
waiting for a program. That single digit confirms the fabric is configured,
the CPU is out of reset and the shared RAM came up zeroed.

### Run it on the board

```bash
cd Software
make                                    # needs build-essential and libssl-dev
export APCA_API_KEY_ID=...              # paper keys; never commit them
export APCA_API_SECRET_KEY=...
sudo -E ./marketstream --dry-run --verbose
```

```
=== FMMA: BTC-USD -> FPGA -> Alpaca (protocol v2) ===
Shared RAM mapped at 0xFF200000 (1024 words).
[LOADER] Writing 154 program words at word 8 (entry word last).
[LOADER] Program verified.
[LOADER] CPU running: protocol v2, heartbeat 41233, position 0.
[FEED] connected, subscribed to BTC-USD ticker
[MARKET] bid 97431.02  ask 97431.98
>>> [FPGA] BUY  (tick 34, 812 us after the quote was published, position 0)
[EXEC] dry run: would send buy 0.001 BTCUSD
```

Drop `--dry-run` to trade the paper account. `--no-fpga` runs the whole
thing on a laptop with no board and no root.

## What is where

| Path | Contents |
|------|----------|
| `Software/HFTtop.v` | FPGA top level (`Code/HFTtop.v` is a synced archive copy) |
| `Code/` | The CPU: ALU, control FSM, PC, IR, flags, register bank, muxes, 7-seg decoder |
| `Software/HPSfgpa2*` | Platform Designer system: HPS + 4 KB dual-port on-chip RAM |
| `Software/protocol.py` | **The memory map.** Generates the C, assembly and Verilog copies |
| `Software/fmma_isa.py` | **The ISA.** What the assembler and the simulator are both built from |
| `Software/Assembler.py` | Assembler → `.h`, `.hex`, `.bin`, `.mif`, `.lst` |
| `Software/fmma_sim.py` | Golden-reference instruction set simulator |
| `Software/trading.asm` | The strategy |
| `Software/MarketStream.c` | The host program: feed, loader, execution, instrumentation |
| `Software/test_*.py` | Python test suites |
| `Testbenches/` | RTL testbenches, the Qsys stub, and `run_sim.sh` |
| `docs/` | The engineering record |

## The memory map, in brief

Word indices into the 4 KB shared RAM. Full contract in
[docs/07](docs/07-shared-memory-protocol.md).

| Words | Direction | Contents |
|-------|-----------|----------|
| 0–7 | — | reserved, must stay zero (a zero word is the CPU's HALT) |
| 8–255 | HPS → FPGA | the CPU program |
| 256–270 | HPS → FPGA | `TICK_SEQ`, `BID`, `ASK`, sizes, configuration, fill reports |
| 320–329 | FPGA → HPS | `HEARTBEAT`, `SIGNAL`, `SIGNAL_SEQ`, `POSITION`, `STATUS`, `REJECTS`, `FW_VERSION` |

Two properties make it safe without any locks: market data is written under
a **seqlock** (the sequence number is odd while the block is being written),
and decisions are published by incrementing a counter **last**, which the
host only ever reads. The two sides never write the same word, and the
testbench asserts it.

## The strategy

Mean reversion on the mid price, with the risk check in hardware:

```
mid2 = bid + ask                                   (twice the mid; no divide)
if mid2 < anchor - 2*THRESH  and  position < +MAX:   BUY
if mid2 > anchor + 2*THRESH  and  position > -MAX:   SELL
anchor = mid2
```

Threshold, position limit and a master switch are all read from shared
memory at run time, so retuning is a command-line flag rather than a
rebuild. [docs/08](docs/08-trading-strategy.md) explains the design, and
§8.6 is explicit about what a real market maker would do that this does not.

## Requirements

**Hardware:** DE1-SoC, a microSD card with a Cyclone V Linux image, Ethernet
with a route to the internet, USB-Blaster.

**Development PC:** Quartus Prime Lite 25.1, Python 3, Icarus Verilog
(`winget install Icarus.Verilog`). See
[docs/10](docs/10-build-guide.md) for the toolchain traps on this machine —
there are several, and two of them will produce a binary that silently
cannot connect to anything.

**On the board:** `build-essential`, `libssl-dev`, and a default route.

## Measured

| | |
|---|---|
| Instruction | 3 cycles = 60 ns, always |
| Strategy loop (staleness bound) | 39 cycles = **780 ns** |
| Quote published → decision published | 195 cycles = **3.90 µs** |
| Jitter | zero — no cache, no interrupts, no OS |
| Program | 154 words of 248 available |

[docs/14](docs/14-latency-and-performance.md) has the breakdown, the
hardware-versus-software comparison, and an honest account of where this
sits relative to the tens of milliseconds the internet contributes.

## Safety

**Paper trading only.** The endpoint is hard-coded to Alpaca's paper API.
Credentials come from the environment and never from the source tree.
Position limits are enforced in the fabric, on the decision path, so a
broken host cannot bypass them.

> **A previously committed API key is still present in this repository's git
> history (commit `d65ee28`). It must be revoked.** See
> [docs/18](docs/18-security-and-compliance.md) §18.4.

## Licence

GPL-2.0 — see [LICENSE](LICENSE). This follows from linking against
mongoose, which is GPL-2.0-only; [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)
lists every third-party component and the alternatives.

## Credits

CPU designed in ECE 3710 by group 1011: Henry Wilson, Bobby Lofgren, Kaleb
Neilson, Carson Ord.

Continued as an ECE 4900 senior project by Carlos Zavala, Kaleb Neilson and
Zhenwei Zhu, advised by Jon Davies.
