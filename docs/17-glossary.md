# 17. Glossary

This project sits across two fields, and each has terms the other finds
opaque. Both are here.

## Hardware and FPGA

**ALM** — Adaptive Logic Module, the basic logic unit of a Cyclone V. The
unit resource usage is reported in.

**AXI** — the ARM bus protocol the HPS uses to talk to the FPGA fabric.

**Bridge, H2F / lightweight H2F** — the HPS-to-FPGA buses. The full-width
one appears at `0xC0000000`; the **lightweight** one, which this project
uses, appears at `0xFF200000`. It is narrower and slower but far simpler,
and at 50 MHz with 4 KB of RAM the difference does not matter.

**BRAM / M10K** — on-chip block RAM. A Cyclone V M10K block is 10 kbit; the
4 KB shared memory uses four of them.

**Conduit** — a Qsys interface that is just a bundle of wires, used here for
the HPS DDR3 pins.

**DDR3** — the external memory the ARM runs from. Owned entirely by the HPS;
the FPGA design only passes the pins through. See
[05](05-fpga-design.md) §5.7 for why its configuration in this project is a
placeholder.

**EMIF / UniPHY** — Intel's external memory interface IP. Quartus **Lite**
does not include it, which is the root of several build workarounds.

**Fitter** — the Quartus stage that places and routes. It dominates the
compile time here because of the HPS hard IP.

**HPS** — Hard Processor System: the dual-core ARM Cortex-A9 built into the
Cyclone V SoC, alongside the FPGA fabric on the same die.

**MIF** — Memory Initialization File, the format Quartus uses to preload a
RAM block. This project deliberately uses **none**, so the shared RAM powers
up zeroed; see [07](07-shared-memory-protocol.md) §7.4.

**mmap** — the Linux call that maps physical addresses into a process. How
the host reaches the bridge, via `/dev/mem`.

**Preloader** — the first-stage boot code on the SD card. It configures
DDR3, which is why the wrong SDRAM parameters in the Qsys system do not
break the board.

**Qsys / Platform Designer** — Intel's system integration tool. Generates
the interconnect between the HPS and the on-chip RAM.

**Read-during-write** — what a RAM returns when one port reads a word another
port is writing in the same cycle. `OLD_DATA` returns the previous contents;
`DONT_CARE` returns something undefined. The distinction is load-bearing
here; [07](07-shared-memory-protocol.md) §7.6.

**Seqlock** — a lock-free pattern: the writer marks a version counter odd
while writing and even when finished, and the reader retries if the counter
was odd or changed. How market data crosses safely.

**SDC** — Synopsys Design Constraints, the timing constraint format.

**Slack** — how much time to spare a path has. Positive means timing is met.

**SoC FPGA** — a chip with both a hard processor and programmable fabric.

**`.sof`** — SRAM Object File, the bitstream Quartus produces.

## Trading

**Ask** — the lowest price anyone is currently willing to sell at. Also
*offer*.

**Bid** — the highest price anyone is currently willing to buy at.

**Crossed / locked market** — bid above the ask (crossed) or equal to it
(locked). Normally impossible within one venue; usually a data error.

**Fill** — an order, or part of one, actually executing.

**Inventory / position** — how much of the asset you are holding. Positive
is *long*, negative is *short*. The thing a market maker most wants to keep
near zero.

**Inventory skew** — shifting both quotes away from your position, so the
side that reduces it is more attractive. Reserved in the memory map, not
implemented; [08](08-trading-strategy.md) §8.6.

**Lot** — the unit of trade size. Here, one `--qty` order: 0.001 BTC by
default.

**Maker / taker** — the maker's order rests on the book; the taker's order
crosses the spread and executes against it. Relevant because Coinbase's
`matches` channel reports the *maker* side, which version 1 of this project
misread as a bid and an ask.

**Market making** — continuously quoting both a bid and an ask, earning the
spread while managing inventory. What this project is named for and, as
[08](08-trading-strategy.md) §8.6 explains, does not yet do.

**Market order** — buy or sell immediately at whatever price is available.
What this system sends.

**Mean reversion** — the assumption that a price which has moved sharply
will move back. The strategy's premise.

**Mid** — the midpoint of bid and ask. The strategy works with *twice* the
mid to avoid a divide; [08](08-trading-strategy.md) §8.3.

**Paper trading** — simulated trading against a broker's real API with fake
money. The only mode this project operates in.

**Spread** — the gap between bid and ask.

**Tick** — one market data update. In this project, one published quote,
numbered by `TICK_SEQ`.

**Top of book** — the best bid and best ask, without the depth behind them.
All this system consumes.

## Project-specific

**Anchor** — the doubled mid at the last quote, against which the next one
is compared.

**Decision engine** — the CPU in the fabric running `trading.asm`.

**Golden model** — `Software/fmma_sim.py`, the reference implementation of
the CPU that the RTL is checked against.

**Host** — the ARM side running Linux and `MarketStream.c`. Also *HPS side*.

**ISS** — instruction set simulator. Same thing as the golden model.

**Lot** — see above; the FPGA counts inventory in these.

**Protocol v1 / v2** — the memory-map contract. v1 is the inherited design
with no consistency mechanism; v2 is the current one.
[07](07-shared-memory-protocol.md) §7.12 compares them.

**Signal** — a decision published by the CPU: 1 buy, 2 sell.

**Word** — 32 bits of the shared RAM. Protocol addresses are word indices;
byte offset = 4 × word index.
