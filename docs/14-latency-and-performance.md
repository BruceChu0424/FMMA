# 14. Latency and performance

Every number in this document was measured, and the command that produced it
is given. Where a number is an estimate rather than a measurement, it says
so.

## 14.1 The headline, and the honest caveat

**The fabric turns a quote into a trading decision in 3.9 µs,
deterministically — measured on hardware at 3 µs minimum, 5 µs mean over
5 000 quotes, with the software model agreeing on all 5 000.**

**That is about 0.01 % of the end-to-end latency of this system.** The other
99.99 % is the public internet between Coinbase and a lab in Logan, Utah.

Both sentences matter. The first is what the project set out to demonstrate
and it is demonstrated. The second is why this is an engineering
demonstration and not a trading system, and saying so is part of doing the
work properly. §14.7 covers what would have to change for the first number to
be the one that mattered.

## 14.2 The latency chain

```
  exchange matching engine
        │
        │  ~20-80 ms   internet + TLS + WebSocket framing      [not measured here,
        ▼                                                       not under our control]
  mongoose delivers the message to handle_ticker
        │
        │  ~2 us       integer parse, two fields               [estimated]
        ▼
  publish_tick writes the seqlock                              ── t0
        │
        │  0 .. 780 ns the CPU is somewhere in its 39-cycle loop
        │  ~3.1 us     snapshot, fill check, strategy, risk, publish
        ▼
  SIGNAL_SEQ increments                                        ── t1   3.9 us
        │
        │  0 .. 1 ms   the host's poll interval (--poll-ms)
        ▼
  poll_fpga sees the edge
        │
        │  ~30-100 ms  TLS + HTTP to the broker                [not measured here]
        ▼
  order accepted
```

`t1 − t0` is the part this project controls, and it is the part that is
deterministic.

## 14.3 Measured: the fabric

From [`../Testbenches/tb_latency.v`](../Testbenches/tb_latency.v), run on the
real RTL against the behavioural Qsys system:

```
$ Testbenches/run_sim.sh
  idle loop period            : 39 cycles = 780 ns
  quote -> signal (decision)  : 195 cycles = 3900 ns
  quote -> suppressed (risk)  : 169 cycles = 3380 ns
```

| Metric | Cycles | Time | Notes |
|--------|-------:|-----:|-------|
| Clock period | 1 | 20 ns | 50 MHz |
| Instruction | 3 | 60 ns | every instruction, no exceptions |
| Halt poll | 1 | 20 ns | while waiting for a program |
| **Idle loop** | **39** | **780 ns** | heartbeat, restart check, fill check, tick check — 13 instructions |
| **Quote → signal published** | **195** | **3.90 µs** | worst case: the quote lands just after the tick check |
| Quote → decision suppressed | 169 | 3.38 µs | the risk path is shorter than the publish path |

The idle loop period is also the **staleness bound**: a quote can sit in
shared memory for at most 780 ns before the CPU notices it.

The same figures come out of the instruction-set simulator
(`test_strategy.TestTiming`), which is how they are regression-tested on
every run without needing Verilog.

### Confirmed on hardware

`fmma-bench` measures the same thing on the real board, from the HPS, and
the two agree:

| | Simulation | Hardware, 5 000 samples |
|---|---|---|
| Best case (quote lands just before the tick check) | 156 cycles = 3.12 µs | **3 µs** (min) |
| Worst case (quote lands just after it) | 195 cycles = 3.90 µs | — |
| Typical | — | **5 µs** (mean) |
| Idle loop | 39 cycles = 780 ns | **0.78 µs** (1 282 151 loops/s) |

The measured minimum sits on the simulated best case and the loop rate
matches to two significant figures, which is the strongest evidence
available that the RTL, the simulator and the silicon are the same
design. The hardware mean is above the simulated worst case because it
includes what simulation cannot: the host's own store to the bridge, the
poll that reads the answer back, and write buffering in the L3
interconnect. See [13](13-test-report.md) §13.5.2.

### Why 195 cycles

| Phase | Instructions | Cycles |
|-------|-------------:|-------:|
| Waiting: up to one full idle loop before the tick check runs | ≤ 13 | ≤ 39 |
| Seqlock: odd check, two loads with cursor arithmetic, re-read, compare, commit | 12 | 36 |
| Validity and sum | 5 | 15 |
| Anchor comparison: load and double the threshold, two band tests | 9 | 27 |
| Decision: re-anchor, enable check, risk check, select the side | 11 | 33 |
| Publish: `SIGNAL`, `SIGNAL_TICK`, `STATUS`, then `SIGNAL_SEQ` last | 13 | 39 |
| Loader/branch overheads | — | ~6 |

## 14.4 Determinism

This is the property that actually distinguishes the fabric, and it is worth
more than the absolute number.

The CPU has no cache, no branch predictor, no interrupts, no DMA contention,
no operating system and no other process. Every instruction takes three
cycles. Therefore **the same inputs take the same number of nanoseconds,
every time** — the jitter is exactly zero, not "small".

The variation in the 195-cycle figure comes entirely from *when the quote
arrives relative to the loop*, which is a sampling artefact, not execution
jitter: the bound is 156–195 cycles and the distribution inside it is
uniform.

Compare the host, where the same arithmetic is subject to scheduler
preemption, cache misses, page faults, interrupt handlers and frequency
scaling. §14.5 measures the mean; the mean is not the problem.

## 14.5 Measured: hardware versus software

`fmma-bench` and `marketstream --bench` run the same strategy in C on the
ARM core and time it with `CLOCK_MONOTONIC`, alongside the fabric's
figures. Measured on the board over the same 5 000 quotes:

| | Mean | Max | What it includes |
|---|---:|---:|---|
| Fabric, quote → decision | 5 µs | 17 µs | full round trip: bridge write, CPU loop, decide, host poll |
| ARM core, same strategy | **0.999 µs** | **13.1 µs** | arithmetic only, no bridge |

The comparison is deliberately narrow, and the narrowness is the point.
The ARM figure times **only the arithmetic** — it does not include the
bridge write, because an FPGA does not remove the need to move data.

The result is the one that was predicted, and it is not flattering to
the fabric on the mean:

> For arithmetic this simple, a 925 MHz application processor has a mean
> latency roughly five times *lower* than a 50 MHz soft CPU reached
> across a bridge. What the fabric provides is a **bounded worst case**
> and freedom from the operating system. In a real system the fabric's
> win comes from replacing the interpreted instruction stream with a
> fixed-function pipeline (§14.7), which this CPU deliberately does not
> do.

Claiming the FPGA is simply "faster" here would be false, and the
instrumentation exists precisely so nobody has to guess.

Note the **maxima**, though, which is where the argument actually lives.
The ARM's worst case is 13.1× its mean; the fabric's is 3.4× its mean,
and the fabric's spread is dominated by *when the host polls*, not by
anything happening in the fabric. The fabric's own execution jitter is
zero (§14.4). Over a longer live run the ARM's tail grew to 22.1 µs
while the fabric's did not move.

### The host's poll interval dominates everything

On the live feed with the default 1 ms poll, the end-to-end figure looks
twenty times worse than it is:

| Poll setting | min | mean | max |
|---|---:|---:|---:|
| `--poll-ms 1` (default) | 5 µs | 157 µs | 1082 µs |
| `--poll-ms 0` (busy) | 5 µs | **12 µs** | 48 µs |

A decision that lands just after a poll waits most of a millisecond to
be noticed. That is **the host, not the fabric** — and it is the single
largest term in the end-to-end latency of the whole system after the
internet itself. Anyone quoting 1082 µs as "FPGA latency" would be
wrong by two orders of magnitude.

The fix is not more FPGA. It is an interrupt from the fabric to the HPS
instead of a poll, which is §14.7's first item.

## 14.6 Resource cost

From `output_files/HFTTop.fit.summary` — see
[13-test-report](13-test-report.md) §13.2 for the current build's figures.
The CPU itself is a small fraction of the device; most of the logic and
essentially all of the placement difficulty come from the HPS hard IP and its
DDR3 interface.

## 14.7 Where the time goes, and what would remove it

| Cost | Cycles | Removable by |
|------|-------:|-------------:|
| Polling for a new quote | 0–39 | A doorbell: an interrupt line or a flag the CPU can wait on instead of re-reading. Saves up to 780 ns. |
| The seqlock read | 36 | A double-buffer with a single published index; one read instead of four. Saves ~20 cycles. |
| Interpreting the strategy at 3 cycles/instruction | ~120 | **A fixed-function pipeline.** This is the big one: the entire decision is about six additions and four comparisons, which is 1–2 clock cycles of combinational logic plus a register. |
| Publishing the result | 39 | Fewer output words, or a wider write. |

A hand-written state machine implementing this exact strategy would produce a
decision in **2–3 clock cycles, 40–60 ns** — roughly 70× faster than the CPU
running the same algorithm. That is the real answer to "why put trading logic
in an FPGA", and this project does not claim to have done it: it built a
programmable engine because the strategy had to be iterable, and it measured
the cost of that choice instead of hiding it.

[16-project-plan](16-project-plan.md) lists the fixed-function datapath as
future work, and the memory map and testbenches would not have to change to
accommodate it — which is the useful thing about having the protocol pinned
down.

## 14.8 Throughput

| Limit | Value | Set by |
|-------|-------|--------|
| Decisions the fabric can produce | ~256,000/s | 195 cycles each |
| Quotes the fabric can consume | ~1,280,000/s | the 780 ns loop — **measured: 1,282,151/s** |
| Quotes Coinbase actually sends | ~5/s | the exchange — **measured: 4.7/s** over 90 s on BTC-USD |
| Orders Alpaca will accept | ~3/s sustained | broker rate limits |

The fabric is over-provisioned by five orders of magnitude relative to the
feed. That is not a design error; it is what makes the latency figure a
property of the design rather than of the load.

`fmma-bench` drove 5 000 quotes at 3 300/s — 700× the live rate — and
the fabric answered every one of them with no missed decisions, which is
the load-independence claim tested rather than asserted.

## 14.9 Reproducing these numbers

```bash
# fabric timing, on the RTL
Testbenches/run_sim.sh            # prints the three figures in §14.3

# the same, in the golden model
cd Software && python -m unittest test_strategy.TestTiming -v

# resource and timing closure
grep -A20 "Fitter Summary" output_files/HFTTop.fit.summary
cat output_files/HFTTop.sta.summary

# fabric latency on real silicon: 5000 synthetic quotes, busy-polled
sudo ./fmma-bench --ticks 5000 --interval 300 --csv lat.csv

# end-to-end on the live feed, no orders sent
sudo ./marketstream --dry-run --bench --threshold 200 --stats 30

# the same, with the host's poll interval removed
sudo ./marketstream --dry-run --threshold 200 --stats 40 --poll-ms 0
```

`fmma-bench` is the one to reach for. It needs no network, no broker and
no OpenSSL, it is repeatable because the quote series is synthetic, and
it checks the fabric's decisions against the software model on every
sample — so a latency number it produces is one where the two halves
also agreed on the answer.
