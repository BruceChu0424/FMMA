# 2. System architecture

## 2.1 The one-sentence version

A Linux program on the ARM core turns a WebSocket feed into integers in a
shared RAM; a custom CPU in the FPGA fabric reads those integers, decides, and
writes an answer back into the same RAM; the Linux program turns the answer
into an order.

## 2.2 The split, and why it is where it is

Everything in this system is either *networking* or *arithmetic*.

Networking — TLS, HTTP, JSON, DNS, TCP retransmits, certificate chains — is
enormous, stateful, and completely unsuited to a hand-built 32-bit CPU with
1024 words of memory. It also does not benefit from being in fabric: the time
is spent waiting for the internet, not computing.

Arithmetic — compare two prices against a band, check an inventory limit,
raise a flag — is trivial, but it is the part where determinism matters. In
fabric it takes a fixed, known number of clock cycles every single time.

So the line is drawn exactly there. The ARM does all the networking; the
fabric does all the deciding. Nothing crosses that line except integers in a
shared memory.

```
            internet                                        internet
               |                                                ^
               v                                                |
   ws-feed.exchange.coinbase.com                paper-api.alpaca.markets
     best_bid / best_ask (TLS)                    POST /v2/orders (TLS)
               |                                                ^
  =============|================================================|===========
   HPS         v            ARM Cortex-A9, Linux                |
   ┌──────────────────────────── MarketStream.c ───────────────────────────┐
   │  mongoose event loop                                                  │
   │    parse "10432.17" -> 1043217          (integer, no float)           │
   │    publish through the seqlock          (docs/07)                     │
   │    poll SIGNAL_SEQ for an edge                                        │
   │    send the order, check the HTTP status, report the fill back        │
   │    timestamp every tick; report latency percentiles                   │
   └───────────┬──────────────────────────────────────────────▲────────────┘
               │ writes: quotes, config, fills   reads: signal, position,
               │                                        heartbeat, status
               │        lightweight AXI bridge, 0xFF200000, 50 MHz
  =============|================================================|===========
   FPGA        v                    port s1                     |
   ┌───────────────────── 4 KB dual-port on-chip RAM ───────────────────────┐
   │  0..7 reserved  |  8..255 program  |  256.. inputs  |  320.. outputs   │
   └───────────▲──────────────────────────────────────────────┬────────────┘
               │ port s2: fetch, load, store                  │
   ┌───────────┴──────────────────────────────────────────────▼────────────┐
   │  Custom 32-bit RISC CPU (ECE 3710 group 1011 design)                   │
   │    16 × 32-bit registers · 3-cycle FSM · runs trading.asm              │
   │    self-starts when the loader writes the entry word                   │
   └────────────────────────────────────────────────────────────────────────┘
               │
               v
            HEX0: low nibble of the PC        KEY[0]: reset the CPU
```

## 2.3 Why a CPU in the fabric, and not a state machine?

A hand-written state machine would be faster than a CPU running an
interpreted-speed instruction stream — three clocks per instruction is not
impressive. Two reasons it is a CPU anyway:

1. **It already existed.** The CPU is the ECE 3710 group 1011 design, and
   reusing it is the premise of the senior project rather than an accident.
2. **The strategy changes far more often than the hardware.** A Quartus
   compile of this design takes about an hour; re-assembling `trading.asm` and
   pushing it over the bridge takes under a second, with no reconfiguration.
   That turnaround is what makes it possible to test a hundred strategy
   scenarios (`test_strategy.py`) instead of four.

The cost is quantified rather than hand-waved: [14](14-latency-and-performance.md)
gives the decision latency and what a fixed-function pipeline would save.

## 2.4 Components

| Component | Where | Language | Responsibility |
|-----------|-------|----------|----------------|
| `MarketStream.c` | ARM / Linux | C11 (gnu11) | Feed, loader, execution, fills, instrumentation |
| `mongoose.c/.h` | ARM / Linux | C (vendored) | TCP/TLS/HTTP/WebSocket |
| `protocol.py` | build host | Python | The memory map, emitted to C, assembly and Verilog |
| `Assembler.py`, `fmma_isa.py` | build host | Python | Assembler and the ISA definition |
| `fmma_sim.py` | build host | Python | Golden-reference instruction set simulator |
| `trading.asm` | FPGA fabric | FMMA assembly | The strategy |
| `HFTtop.v` | FPGA fabric | Verilog | Top level: CPU + Qsys system + reset + display |
| `Code/*` | FPGA fabric | Verilog | CPU: ALU, FSM, PC, IR, flags, register bank, muxes |
| `HPSfgpa2.qsys` | FPGA fabric | Qsys | HPS hard IP + 4 KB dual-port on-chip RAM |

## 2.5 The data path of one quote

This is the whole system in nine steps. Times are measured; see
[14](14-latency-and-performance.md).

1. Coinbase sends a `ticker` message over the WebSocket. *(tens of ms from
   the exchange, not under our control)*
2. mongoose reassembles the TLS record and the WebSocket frame.
3. `handle_ticker` finds `best_bid` and `best_ask` and converts them to
   integer cents without touching a float.
4. `publish_tick` writes `TICK_SEQ` odd, the four data words, then `TICK_SEQ`
   even. The odd value is what tells the CPU "do not read this yet".
5. The CPU is looping every **780 ns**. On its next pass it sees `TICK_SEQ`
   has changed, re-reads it after the data to confirm nothing moved, and
   commits the snapshot.
6. It applies any fill the host reported, compares the doubled mid against its
   anchor, and checks the position limit.
7. If it decides to trade it writes `SIGNAL` and `SIGNAL_TICK`, then
   increments `SIGNAL_SEQ`. **3.9 µs** have passed since step 4.
8. The host sees `SIGNAL_SEQ` move, reads the decision, and POSTs the order.
   *(tens of ms to the broker)*
9. On a 2xx response it reports the fill, so the CPU's inventory and the
   broker's agree.

## 2.6 The two hard problems

Almost all of the design effort in this project went into two places, and both
have their own document.

**Consistency without locks** ([07](07-shared-memory-protocol.md)). Two
processors share a RAM with no mutex, no atomics and no interrupt line. The
host can write a price in the middle of the CPU reading one; the CPU can raise
a signal in the middle of the host reading one. Version 1 of this project had
neither problem solved, and the symptoms — an occasional trade on a price that
never existed — are exactly the kind that do not show up in a demo. The fix is
a seqlock in one direction and a publish-last sequence counter in the other,
plus configuring the RAM so a concurrent read returns *old* data rather than
undefined data.

**Not trusting the toolchain** ([04](04-isa-reference.md),
[12](12-verification-plan.md)). The CPU was inherited with an assembler that
happily emitted instructions the hardware decodes differently or not at all.
The answer was to make one file the definition of the ISA, generate the
assembler and the simulator from it, and then prove the simulator matches the
hardware on ~9,500 generated vectors. A `SUB` with an immediate now means what
it says, and if it ever stops meaning that, a test fails.
