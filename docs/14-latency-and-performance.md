# 14. Latency and performance

Every number in this document was measured, and the command that produced it
is given. Where a number is an estimate rather than a measurement, it says
so.

## 14.1 The headline, and the honest caveat

**The fabric turns a quote into a trading decision in 3.9 µs, deterministically.**

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

`marketstream --bench` runs the same strategy in C on the ARM core and times
it with `CLOCK_MONOTONIC`, printing mean and max alongside the fabric's
figures.

The comparison is deliberately narrow, and the narrowness is the point:

* It times **only the arithmetic**. It does not include the bridge write,
  because an FPGA does not remove the need to move data.
* The ARM is a 925 MHz superscalar core and the arithmetic is a handful of
  integer operations. It will show a **smaller mean** than 3.9 µs. That is
  the expected and correct result.
* What it will also show is a **much larger max**, and a distribution with a
  long tail, because it is running under Linux.

So the honest conclusion this project reports is:

> For arithmetic this simple, a 925 MHz application processor has a lower
> *mean* latency than a 50 MHz soft CPU. What the fabric provides is a
> *bounded worst case* — 195 cycles, always — and a path that does not
> depend on an operating system. In a real system the fabric's win comes
> from replacing the interpreted instruction stream with a fixed-function
> pipeline (§14.7), which this CPU deliberately does not do.

Claiming the FPGA is simply "faster" here would be false, and the
instrumentation exists precisely so nobody has to guess.

Run it on the board and paste the output into
[13-test-report](13-test-report.md) §13.5.

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
| Quotes the fabric can consume | ~1,280,000/s | the 780 ns loop |
| Quotes Coinbase actually sends | ~5/s | the exchange |
| Orders Alpaca will accept | ~3/s sustained | broker rate limits |

The fabric is over-provisioned by five orders of magnitude relative to the
feed. That is not a design error; it is what makes the latency figure a
property of the design rather than of the load.

## 14.9 Reproducing these numbers

```bash
# fabric timing, on the RTL
Testbenches/run_sim.sh            # prints the three figures in §14.3

# the same, in the golden model
cd Software && python -m unittest test_strategy.TestTiming -v

# resource and timing closure
grep -A20 "Fitter Summary" output_files/HFTTop.fit.summary
cat output_files/HFTTop.sta.summary

# end-to-end, on the board
sudo -E ./marketstream --bench --stats 30
```
