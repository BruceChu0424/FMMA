# 8. Trading strategy

## 8.1 What the CPU decides

For each new quote:

```
mid2 = bid + ask                        (twice the mid; see §8.3)

if no anchor yet:            anchor = mid2                    no signal
else if mid2 < anchor - 2T:  anchor = mid2   BUY   (the market fell)
else if mid2 > anchor + 2T:  anchor = mid2   SELL  (the market rose)
else:                        anchor = mid2                    no signal
```

`T` is `CFG_THRESH`, in cents, settable at run time. Every decision then
passes the risk filter in [09](09-risk-management.md) before it is published.

That is the whole thing. It is a short-horizon mean-reversion trigger: buy
when the market has just dropped a long way, sell when it has just jumped.

## 8.2 Why this strategy

Three constraints shaped it, and it is worth being clear that they are
engineering constraints, not a claim that this is a good way to make money:

1. **It has to fit the machine.** Sixteen registers, no divide, no stack, 3
   cycles per instruction, and 248 words of program space. Anything with a
   rolling window, a variance estimate or an order book does not fit.
2. **It has to be testable.** Every branch of the decision table above is
   reachable from a two-quote scenario, which is why
   `test_strategy.py` can cover all of them and `tb_fmma` can re-check the
   important ones on real RTL.
3. **It has to be honest about the feed.** Quotes arrive every couple of
   hundred milliseconds over the public internet. No strategy that depends
   on *being first* is testable on this infrastructure, so the project
   demonstrates deterministic low-latency decision-making rather than
   claiming an edge.

§8.7 is explicit about what this is not.

## 8.3 Why twice the mid

The mid price is `(bid + ask) / 2`. Dividing by two on this CPU means a shift
instruction, and the strategy compares the mid against a band on both sides,
so the factor of two cancels anyway:

```
    mid  < anchor_mid  - T     ⟺     bid+ask  <  anchor_sum  - 2T
```

Working in `bid + ask` and doubling the threshold (`ADD R8, R8`, one
instruction) is exactly equivalent, one instruction cheaper, and loses no
precision to truncation.

The cost is headroom: the sum must stay inside a positive signed 32-bit
value, because the comparisons are signed. With prices in cents that ceiling
is $10.7 M per side — about a hundred times the current BTC price. With
version 1's scale of 10,000 it was $214,748, roughly twice the BTC price,
which is far too close for a system that is supposed to run unattended.
[07](07-shared-memory-protocol.md) §7.11 has the table.

## 8.4 The anchor

The anchor is the mid at the last time the CPU looked, updated on **every**
quote, whether or not it traded.

This makes the trigger a *rate* test rather than a *level* test: it fires on
a move of more than `T` between consecutive quotes, not on a cumulative drift
away from some starting price. A slow slide of $100 over fifty quotes
produces nothing; a single $20 jump produces one signal.

Re-anchoring on a decision is what stops a single move producing a signal on
every subsequent quote.
`test_strategy.test_decision_re_anchors_so_one_move_fires_once` pins that
down, and `test_a_staircase_fires_on_each_step` pins down the complementary
case — four successive $21 drops give four buys, not one.

## 8.5 Parameters

| Parameter | Word | Default | Effect |
|-----------|------|---------|--------|
| `CFG_THRESH` | 261 | 1000 (= $10.00) | smaller trades more often and is noisier; larger waits for bigger moves |
| `CFG_MAX_POS` | 262 | 5 lots | how far the inventory may run in either direction |
| `CFG_ENABLE` | 263 | set by the loader | kill switch |
| `CFG_POSITION` | 270 | 0 | inventory the CPU adopts at startup and on restart |

All four are read from shared memory at run time, so retuning is a command
line flag (`--threshold`, `--max-pos`), not a rebuild. On a 50 MHz CPU with
a 780 ns loop the cost of reading a configuration word per decision is
irrelevant, and the flexibility is worth far more.

## 8.6 What is not implemented: two-sided quoting

The project is called a market maker, and a real market maker quotes both
sides continuously and earns the spread. This one does not, and the gap
should be stated plainly rather than papered over.

The memory map reserves what a quoting strategy would need —
`CFG_HALF_SPREAD`, `CFG_SKEW`, `QUOTE_BID`, `QUOTE_ASK` — and the
arithmetic is within reach of this CPU:

```
mid2   = bid + ask
skew   = position * CFG_SKEW          (MUL exists; lean against inventory)
quote_bid2 = mid2 - 2*CFG_HALF_SPREAD - 2*skew
quote_ask2 = mid2 + 2*CFG_HALF_SPREAD - 2*skew
```

What is *not* within reach is everything around it: resting limit orders,
cancel/replace, acknowledgement tracking, partial fills, and an order
lifecycle state machine on the host. That is a substantially larger project
than the decision arithmetic, and it needs a broker API that supports fast
cancel/replace — Alpaca's REST endpoint, at tens of milliseconds per call,
does not.

So the honest description of this system is: **a latency-optimised
decision engine with a market-making memory map, running a mean-reversion
trigger.** [16](16-project-plan.md) lists two-sided quoting as the first item
of future work and [01](01-requirements.md) §1.2 puts it out of scope.

## 8.7 What this strategy is not

* **Not profitable.** It has no edge. It trades on a public feed with a
  latency measured in tens of milliseconds, against participants measured in
  microseconds. It is a correctness and latency demonstration.
* **Not backtested.** There is no historical data pipeline in this project.
  The scenario suite proves the decision table is implemented correctly, not
  that the decision table is a good one.
* **Not risk-free even on paper.** See [09](09-risk-management.md) for what
  the limits do and do not protect against.

## 8.8 Implementation notes

Source: [`../Software/trading.asm`](../Software/trading.asm), 154 words at
word 8.

Register allocation (the binding constraint — there are sixteen and the
program needs all of them):

| Reg | Holds | Reg | Holds |
|-----|-------|-----|-------|
| R0 | constant 0 | R8 | scratch |
| R1 | constant 1 | R9 | anchor |
| R2 | `&TICK_SEQ` | R10 | scratch |
| R3 | `&HEARTBEAT` | R11 | last `TICK_SEQ` consumed |
| R4 | scratch address | R12 | heartbeat counter |
| R5 | bid | R13 | position |
| R6 | ask | R14 | last `FILL_SEQ` consumed |
| R7 | scratch | R15 | `LOOP` address, for `JUC` |

Constants that do not fit (the threshold, the position limit) live in memory
and are read on the decision path, which costs two instructions and is only
reached when something is actually happening.

Two placement tricks keep the idle loop short:

* `CFG_RESTART` sits immediately before `FILL_SEQ` in the memory map, so one
  `LDI` gets the address register there and a single `ADD` moves it on. That
  is four instructions saved on every pass of the loop.
* `BID` and `ASK` are adjacent to `TICK_SEQ`, so the snapshot read walks the
  cursor with `ADD R4, R1` instead of rebuilding an address.

Structure:

```
INIT:            constants, adopt inventory, clear outputs,
                 probe the datapath, publish FW_VERSION
LOOP:            heartbeat, restart check, fill check, tick check   (13 instr)
  seqlock read   odd check, read bid and ask, re-read and compare
  strategy       validity, sum, anchor comparison
  DO_BUY/SELL    enable check, risk check, then publish or reject
  EMIT           SIGNAL, SIGNAL_TICK, then SIGNAL_SEQ last
  RISK_BLOCK     STATUS, REJECTS
  DO_RESTART     clear the request, jump to INIT
  ISA_MISMATCH   heartbeat only; never publish a version
```

## 8.9 Verification

| Property | Where |
|----------|-------|
| the whole decision table, ~30 scenarios | `Software/test_strategy.py` |
| the same decisions on real RTL | `Testbenches/tb_fmma.v` steps 3–7 |
| re-anchoring, staircases, one-sided books | `test_strategy.TestDecisions` |
| risk interaction | `TestRiskLimits`, `tb_fmma` steps 9–11 |
| restart semantics | `TestSoftwareRestart`, `tb_fmma` step 13 |
| timing | `tb_latency`, `TestTiming` |

[12](12-verification-plan.md) explains how the pieces divide the work.
