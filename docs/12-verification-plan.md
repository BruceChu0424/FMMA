# 12. Verification plan

## 12.1 Strategy

Five layers, each proving something the others cannot, with an explicit
hand-off between them.

```
  ┌──────────────────────────────────────────────────────────────────┐
  │ 4. On-board validation                    docs/11, tools/deploy  │
  │    the real feed, the real broker, the real chip                 │
  ├──────────────────────────────────────────────────────────────────┤
  │ 3. RTL, full chain            Testbenches/tb_fmma.v, tb_latency.v│
  │    the real top level against a behavioural Qsys system,         │
  │    driven through the real bridge port                           │
  ├──────────────────────────────────────────────────────────────────┤
  │ 2. RTL, unit                             Testbenches/tb_alu.v    │
  │    the ALU against the golden model, ~9,500 generated vectors    │
  ├──────────────────────────────────────────────────────────────────┤
  │ 1. Model                    Software/test_toolchain.py,          │
  │    the ISA, the assembler, the simulator, the strategy           │
  │                                          test_strategy.py        │
  ├──────────────────────────────────────────────────────────────────┤
  │ 0. Host unit tests                   Software/tests/test_units.c │
  │    fixed point, JSON, the C strategy, P&L - no board needed      │
  └──────────────────────────────────────────────────────────────────┘
```

The load-bearing idea is layer 2. A Python simulator that claims to model the
hardware is worth nothing on its own; `tb_alu.v` runs the *same vectors* that
the golden model generated through the *actual RTL* and fails on any
disagreement. That is what licenses layers 1 and 3 to use the model.

## 12.2 What each layer is responsible for

| Layer | Proves | Cannot prove |
|-------|--------|--------------|
| 0. C units | The host's parsing, strategy and P&L are right, without a board, a network or root. | Anything about the fabric. |
| 1. Model | The decision table is right in every scenario; the assembler cannot emit something the hardware misreads; the protocol logic is sound. Fast enough (2 s) to run on every edit. | That the hardware behaves like the model. |
| 2. RTL unit | The ALU's results and all five flags match the model for every opcode, every edge value and every shift amount. | Anything about control flow or timing. |
| 3. RTL full chain | The real top level, driven through the real bridge port, implements the protocol: boot, seqlock, signalling, risk, restart, reset, port discipline. Latency is inside budget. | That the synthesised netlist matches the RTL, or that the board's peripherals work. |
| 4. On-board | Everything else: configuration, the bridge on real silicon, TLS to real endpoints, a real broker. | Nothing is left, which is why this step closes the project. |

## 12.3 Test inventory

### Layer 0 — C unit tests (63 checks, instant)

`Software/tests/test_units.c` covers the pure functions in the host
application, on the development machine:

| Group | What it covers |
|-------|----------------|
| fixed point | exact decimal parsing, truncation not rounding, negative values, stopping at a non-numeric character, saturation, formatting round-trip, the price clamp |
| JSON | field extraction, missing fields, numeric-vs-string fields, truncation rejected, and the two substring traps (`last_match` is not `match`, a subscription ack is not a `ticker`) |
| strategy | the whole decision table, re-anchoring, one-sided books, both risk limits, reduce-at-the-limit, fills |
| P&L | average-cost accounting both directions, averaging in, crossing through zero, marking to market, the loss limit halting and staying halted, the stale-feed watchdog blocking then recovering |

This layer is what makes `--bench` meaningful: it proves the C strategy
really is the same algorithm as the assembly one.

### Layer 1 — Python (96 tests, ~2 s)

`Software/test_toolchain.py` (48 tests)

| Group | What it covers |
|-------|----------------|
| `TestEncoding` | field layout for every format; branch displacement is relative to the branch; labels resolve to absolute addresses; `LDI`/`NOP` expansion; `.equ`, `.word`, three comment styles |
| `TestRejections` | every condition code the hardware does not decode; the degenerate code 1100 is never emitted; zero-word instructions; out-of-range displacements and immediates; bad registers, unknown mnemonics, duplicate labels |
| `TestRoundTrip` | encode→decode for every R-type and I-type combination, every displacement in −128…127, every load/store register pair |
| `TestAlu` | add/sub/wrap/carry; logical ops clear the flags; `CMP` signed and unsigned; shifts in both directions including the sign; the legacy shift model still reproduces the old bug |
| `TestConditions` | all six conditions against a Python signed comparison, over a grid of boundary values |
| `TestSimulator` | LDI-then-arithmetic, immediate operand order, load/store through a register, backward branches, register jumps, the halt state, self-start, 3-cycle timing, undefined-encoding stall |

`Software/test_strategy.py` (48 tests, covering both strategies)

| Group | What it covers |
|-------|----------------|
| `TestStartup` | version and status published; outputs start clear; heartbeat advances |
| `TestSoftwareRestart` | the request is consumed and does not loop; state is re-initialised; inventory is adopted from the host rather than zeroed (positive and negative); the strategy works again afterwards; reloading an image restarts cleanly |
| `TestDecisions` | first quote only anchors; small move does nothing; fall → buy; rise → sell; the signal names its quote; re-anchoring means one move fires once; a staircase fires on each step; a one-sided book is ignored |
| `TestSeqlock` | an odd sequence number is not consumed; a torn snapshot is retried rather than used; a repeated quote is processed once |
| `TestRiskLimits` | both limits block; both allow the reducing side; just inside the limit is allowed; the master switch suppresses everything; re-enabling resumes |
| `TestFillAccounting` | buys and sells move the position; a fill is applied once; the position survives many quotes |
| `TestTiming` | idle loop is exactly 39 cycles; a decision completes inside 250 cycles |
| `TestMarketMaker` | the quoting strategy: quotes straddle the mid, the first tick only quotes, a later move lifts the ask or hits the bid, a wider spread trades less, inventory skew moves both quotes and makes the reducing side easier to reach, the risk limit and the master switch still apply |

### Layer 2 — `Testbenches/tb_alu.v`

9,548 vectors generated by `Software/gen_alu_vectors.py` from the golden
model: every opcode against a grid of sign-boundary and realistic values,
every shift amount 0–31, carry in both states for `ADDC`/`SUBC`, plus 256
deterministic pseudo-random cases per opcode. Both the 32-bit result and all
five flag bits are compared.

### Layer 3 — `Testbenches/tb_fmma.v` (31 assertions)

| Step | Asserts |
|------|---------|
| 1 | the CPU parks at the entry word with the RAM empty; no heartbeat |
| 2 | after the loader runs: version published, status running, heartbeat advancing |
| 3–4 | first quote anchors; a small move produces nothing |
| 5 | a $20 fall produces BUY, tagged with the quote that caused it |
| 6 | a $20 rise produces SELL |
| 7 | a quiet market produces nothing |
| 8 | fills move the inventory in both directions |
| 9 | the position limit blocks a buy, counts it, and sets the status bit |
| 10 | the reducing side is still allowed at the limit |
| 10b | the inventory can be flattened |
| 11 | the master switch suppresses everything and reports itself |
| 12 | a half-written quote is ignored, and acted on once completed |
| 13 | `CFG_RESTART` consumes the request and re-initialises state |
| 14 | `KEY[0]` holds the CPU in reset and it recovers on release |
| 15 | **the two RAM ports never wrote the same word in the same cycle** |

`Testbenches/tb_latency.v` measures three numbers on the same RTL and fails
if any exceeds its budget.

### Layer 4 — on the board

[11-board-bringup](11-board-bringup.md) is the procedure, and §11.8 lists the
six output lines that constitute the checks.

## 12.4 The simulation model, and where it is optimistic

`Testbenches/HPSfgpa2_stub.v` stands in for the Qsys system. A stub that is
more forgiving than the hardware makes "all tests passed" meaningless, so
what it models and what it does not is worth stating.

| Aspect | Real hardware | Stub | Faithful? |
|--------|---------------|------|-----------|
| Depth and width | 1024 × 32, true dual port | same | yes |
| Read latency | address registered, output combinational — 1 cycle | registered output — 1 cycle | yes, for a stable address |
| Mixed-port read-during-write | `OLD_DATA` | non-blocking reads evaluated before writes = old data | yes |
| Same-address write collision | undefined | **counted and reported as an error** | stricter than hardware, deliberately |
| Host port | AXI through the interconnect | a direct Avalon-style port driven by tasks | simplified: no AXI burst or backpressure modelling |
| Power-up contents | zeroed (no init file) | zeroed | yes |
| Reset | from `h2f_reset` while the HPS boots | an 8-cycle counter | simplified; the CPU does not depend on it |

The two simplifications are both on the host side, and the reason they are
acceptable is that the protocol does not depend on AXI semantics — it depends
on write *order*, which the stub preserves, and on the RAM's read-during-write
behaviour, which the stub models exactly.

The one thing the stub is stricter about is the write-collision check, which
is a property the real hardware would simply get wrong silently.

**What no simulation here covers:** the synthesised netlist (no gate-level
simulation — there is no Questa licence), the real AXI bridge, and the HPS
itself.

## 12.5 Regression

```bash
Testbenches/run_sim.sh
```

Regenerates the memory map, the program and the ALU vectors; runs all four
automated stages; exits non-zero on any failure. About 25 seconds.

Run it before every commit. It catches, among other things, a memory map
edited in one language but not the others, a strategy change that breaks the
timing budget, and an RTL change that makes the hardware diverge from the
model.

## 12.6 Deliberate gaps

| Not tested | Why | Risk |
|------------|-----|------|
| Gate-level simulation | No Questa licence; Icarus cannot read the Quartus netlist. | Low: timing is closed with positive slack and the design is small and fully synchronous. |
| The real AXI bridge | Would need a full Qsys testbench with the HPS BFM, which Lite cannot generate. | Low: the bridge is vendor IP and the readback verify in the loader catches a wrong address. |
| Coinbase and Alpaca protocol handling against the live services | Cannot be made deterministic in CI. | Medium: mitigated by `--dry-run`, `--no-fpga`, and the fact that both were exercised manually. |
| Long-duration soak | No unattended board time yet. | Medium: sequence-number wrap and heartbeat wrap are argued safe (equality comparisons only) but not observed. |
| Power, thermal, EMC | Out of scope for a lab demonstration. | n/a |

## 12.7 Traceability

Every requirement in [01-requirements](01-requirements.md) names the test
that verifies it, in the right-hand column of §1.3 and §1.4.
[13-test-report](13-test-report.md) gives the results.
