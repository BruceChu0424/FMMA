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
  │  marketstream  (13 modules under Software/src/)                   │
  │    parse "97431.02" -> 9743102   (exact integers, no float)       │
  │    publish through a seqlock, poll SIGNAL_SEQ for an edge         │
  │    execute, follow the order to a fill, report it back            │
  └───────────────┬──────────────────────────────────▲────────────────┘
                  │  lightweight AXI bridge, 0xFF200000, 50 MHz
  ┌───────────────▼──────────────────────────────────┴────────────────┐
  │            4 KB dual-port on-chip RAM  (the contract)             │
  │   0-7 reserved │ 8-255 program │ 256+ inputs │ 320+ outputs       │
  └───────────────▲──────────────────────────────────┬────────────────┘
                  │  port s2: fetch / load / store   │
  ┌───────────────┴──────────────────────────────────▼────────────────┐
  │  Custom 32-bit RISC CPU running trading.asm / market_maker.asm    │
  │    16 registers · 3 cycles per instruction · 780 ns loop          │
  │    strategy + position limits, enforced in the fabric             │
  └───────────────────────────────────────────────────────────────────┘
```

## Status

| | |
|---|---|
| Simulation | **green** — 99 Python tests, 63 C unit checks, 9,548 ALU equivalence vectors, 31 full-chain RTL assertions, 10 ISA conformance checks, ~25 s |
| FPGA build | **timing closed** at 50 MHz — see [docs/13](docs/13-test-report.md) |
| Host program | **builds clean** under `-Wall -Wextra`; cross-built static for the board |
| On board | **running** — CPU in the fabric answers a quote in **3–4 µs min / 5 µs mean** over 5,000 quotes, 0 missed, 0 disagreements with the software model |
| Live market data | **running** — Coinbase BTC-USD → fabric → decision, 424 quotes / 23 decisions in 90 s |
| Paper orders | **not run** — the key committed in `d65ee28` must be revoked first ([docs/18](docs/18-security-and-compliance.md)) |

Measured, with the commands that produced every figure, in
[docs/13](docs/13-test-report.md) §13.5 and
[docs/14](docs/14-latency-and-performance.md).

## Start here

* **[docs/](docs/README.md)** — the engineering record, 18 documents
* **[docs/07-shared-memory-protocol.md](docs/07-shared-memory-protocol.md)** — the HPS↔FPGA contract, and the most important thing to read
* **[docs/11-board-bringup.md](docs/11-board-bringup.md)** — bare board to running demo
* **[CHANGELOG.md](CHANGELOG.md)** — what changed and why

## Quick start

Five stages, in order. Each one is worth doing before the next,
because each one fails in a way the next one would only obscure.

### 1. Run the tests — no hardware needed

```bash
tools/sim.sh
```

About 25 seconds, six stages, prints `all green` and the measured
latency figures. It runs in a container, so nothing has to be
installed; if you already have Icarus Verilog and Python 3, run
`Testbenches/run_sim.sh` directly instead.

This is also the fastest way to see what the project *is*: the output
names every property that is checked and what it measured.

### 2. Build the FPGA image

```bash
quartus_sh --flow compile HFTTop        # about an hour, mostly fitting
```

Expect **0 errors** and exactly two Critical Warnings, both about HPS
DDR3 pin placement ([docs/13](docs/13-test-report.md) §13.2). The
`output_files/HFTTop.sof` and `.rbf` in this repository are built from
the committed sources, so this step can be skipped the first time
through.

### 3. Set MSEL, once, before powering the board

**`SW10` position 4 OFF, position 5 ON** — MSEL = `01010`, Fast
Passive Parallel x16. The factory setting is Active Serial, in which
the FPGA loads itself from flash and **the HPS cannot configure it at
all**: every bitstream, including Terasic's own, is refused with
`Invalid MSEL setting` and a timeout. It looks exactly like a bad
bitstream and is not. This cost a day; [docs/11](docs/11-board-bringup.md)
§11.4.

Power-cycle after moving the switches. Connect USB-UART and Ethernet.

### 4. Bring the board up

```bash
python tools/deploy.py --port COM5 status   # what state is it in?
python tools/deploy.py --port COM5 net      # DHCP on eth0
python tools/deploy.py --port COM5 fpga     # configure, with safety checks
```

`fpga` prints `done: user mode`. **Now look at `HEX0`: it should show a
steady `8`.** Do not skip that. On Cyclone V there is no timeout on the
HPS-to-FPGA bridge — touching it while the fabric is unconfigured hangs
the board hard enough to need the power pulled, with no software
recovery. Every tool here checks the FPGA manager first, but the check
cannot prove the *right* design is loaded. `HEX0` can.

```bash
python tools/deploy.py --port COM5 probe ramtest
```

`PASS - 256 words, 32 data bits, no errors` means the window really is
our shared RAM. The stock reference design puts PIO registers at this
address and fails this immediately.

### 5. Get the software onto the board

```bash
python tools/deploy.py --port COM5 push     # sources
tools/crossbuild.sh                         # static armhf binaries
python tools/deploy.py --port COM5 pushbin  # binaries
```

`marketstream` **cannot be built on the board**: the stock image ships
`libssl.so` without its headers and its Ubuntu 12.04 archives have been
retired, so `libssl-dev` cannot be installed. `crossbuild.sh` produces a
static armhf binary from a container; the first run builds the image and
takes a few minutes. The two diagnostics need nothing but libc and do
build on the board, in about a second (`make probe bench`).

### Then: see it work

```bash
./fmma-bench --selftest                     # 21 protocol checks on the fabric
./fmma-bench --ticks 5000 --interval 300    # latency, and hardware/software agreement
./marketstream --dry-run --threshold 200 --stats 30
```

```
=== FMMA: BTC-USD -> FPGA -> paper trading (protocol v2) ===
[  0.000] info  fpga     shared RAM mapped at 0xFF200000, 1024 words
[  0.000] info  fpga     writing 154 program words at word 8, entry word last
[  0.000] info  fpga     program verified
[  0.100] info  fpga     CPU running: protocol v2, heartbeat 128337, position 0
[  0.827] info  feed     connected, subscribed to BTC-USD ticker
[  0.951] info  app      >>> FPGA BUY  (tick 10904, 5 us after the quote, fabric position 0)
[  0.951] info  exec     dry run: would send buy 0.001 BTCUSD
```

**That `>>> FPGA BUY` line is the project working**: real Coinbase
market data, and a CPU we designed, running in the fabric, deciding in
five microseconds.

To trade the paper account, export `APCA_API_KEY_ID` and
`APCA_API_SECRET_KEY` and drop `--dry-run` — with `sudo -E`, because
plain `sudo` strips the environment. **Read
[docs/18](docs/18-security-and-compliance.md) first: the key committed
in `d65ee28` is in this repository's history and must be revoked.**

`--no-fpga` runs the feed, the strategy and the broker path on a laptop,
with no board and no root.

## What is where

| Path | Contents |
|------|----------|
| `Software/HFTtop.v` | FPGA top level (`Code/HFTtop.v` is a synced archive copy) |
| `Code/cpu_core.v` | The CPU, assembled from the modules below |
| `Code/reset_ctrl.v` | Power-on reset and the `KEY[0]` button |
| `Code/` | ALU, control FSM, PC, IR, flags, register bank, muxes, 7-seg decoder |
| `Software/HPSfgpa2*` | Platform Designer system: HPS + 4 KB dual-port on-chip RAM |
| `Software/protocol.py` | **The memory map.** Generates the C, assembly and Verilog copies |
| `Software/fmma_isa.py` | **The ISA.** What the assembler and the simulator are both built from |
| `Software/Assembler.py` | Assembler → `.h`, `.hex`, `.bin`, `.mif`, `.lst` |
| `Software/fmma_sim.py` | Golden-reference instruction set simulator |
| `Software/trading.asm` | The mean-reversion strategy |
| `Software/market_maker.asm` | Two-sided quoting with inventory skew |
| `Software/src/` | The host program: 13 modules, plus `fmma_probe.c` |
| `Software/tests/` | C unit tests (no board needed) |
| `Software/test_*.py` | Python test suites |
| `Testbenches/` | RTL testbenches, the Qsys stub, and `run_sim.sh` |
| `tools/` | `boardctl.py` (serial console), `deploy.py` (bring-up) |
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

**Hardware:** DE1-SoC, a microSD card with a Cyclone V Linux image,
Ethernet with a route to the internet, and a USB cable for the serial
console. A USB-Blaster is *not* required — the FPGA is configured from
Linux over the same serial link.

**Development PC:** Docker, plus Python 3 with `pyserial` for the board
tools. That covers everything except building the bitstream:
`tools/sim.sh` runs the verification suite and `tools/crossbuild.sh`
builds the armhf binaries, so neither Icarus Verilog nor an ARM
toolchain has to be installed. There is no iverilog package in winget
and Quartus's bundled Questa wants a licence file, so on Windows the
container is the practical route.

**To rebuild the bitstream:** Quartus Prime Lite 25.1. The built `.sof`
and `.rbf` are committed, so this is only needed after an RTL change.

**On the board:** a default route, and nothing else. The two
diagnostics build there against libc alone; `marketstream` cannot be
built there at all and is cross-compiled
([docs/10](docs/10-build-guide.md) §10.4a).

[docs/10](docs/10-build-guide.md) lists the toolchain traps — there are
several, and two of them produce a binary that silently cannot connect
to anything.

> **Never read the HPS-to-FPGA bridge unless the FPGA is configured.**
> Cyclone V has no bus timeout, so the access never completes and the
> board hangs hard enough to need a power cycle. Everything here checks
> `/sys/class/fpga/fpga0/status` first.

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
