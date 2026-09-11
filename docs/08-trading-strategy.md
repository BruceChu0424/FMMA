# 8. Trading strategy

## 8.0 Two strategies

| File | What it does | Words | Use it when |
|------|--------------|------:|-------------|
| `trading.asm` | mean-reversion trigger on the mid | 154 | the default; simplest to explain and to test |
| `market_maker.asm` | two-sided quoting with inventory skew | 174 | demonstrating what the project is named for |

Both implement the same protocol, the same risk layer and the same
restart semantics; they differ only in the decision. Sections 8.1-8.5
describe `trading.asm`; §8.6 describes `market_maker.asm`.

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

## 8.6 The quoting strategy

`market_maker.asm` is the second strategy in the repository, and it is
the one the project is named for. Where `trading.asm` reacts to a move,
this one continuously shows a two-sided quote and trades when the market
comes to its price.

```
mid2  = bid + ask                       (twice the mid, as above)
skew2 = 2 * position * CFG_SKEW         lean against inventory
qbid2 = mid2 - 2*CFG_HALF_SPREAD - skew2
qask2 = mid2 + 2*CFG_HALF_SPREAD - skew2
```

`QUOTE_BID` and `QUOTE_ASK` are published every tick, halved once at the
end with a single right shift - which is only possible because the 2026
rebuild fixed the shifter, and is why this program's startup probe
checks `LSH` as well as `SUB`.

**The skew is the interesting part.** Long inventory pushes *both*
quotes down: the ask becomes easier to lift, so the position is more
likely to be reduced, and the bid becomes harder to hit, so it is less
likely to grow. Short inventory does the reverse. `CFG_SKEW` is how far
to move per lot held. `test_skew_makes_the_reducing_side_easier_to_reach`
pins the behaviour down: with the same market move, a flat book does not
trade and a long book sells.

Measured on the board, with a market of 50000.00 / 50002.00,
`CFG_HALF_SPREAD = 200` and `CFG_SKEW = 50`:

| Inventory | Our bid | Our ask | |
|-----------|---------|---------|---|
| flat | 49999.00 | 50003.00 | symmetric, $2.00 either side of the mid |
| long 3 | 49997.50 | 50001.50 | both **down $1.50** = 3 x $0.50 |
| short 3 | 50000.50 | 50004.50 | both **up $1.50** |

### The bootstrap trap, and what it cost

This strategy trades when a *later* market move reaches the quotes it
was already showing, so the tick path has to test the market against
the previous tick's quotes and not this tick's - quotes derived from
the current mid sit inside the current spread by construction and
could never be reached. The guard for the very first tick, when there
are no previous quotes, is `R9 == 0`.

`R9` was not cleared on entry.

Clearing the published `QUOTE_BID` and `QUOTE_ASK` words is not the
same thing, and `INIT` did do that: those are what the *host* reads,
`R9` and `R10` are what the *strategy* compares against. With `R9`
holding whatever the previous program left, the guard never fired, the
first tick was measured against a stale ask and traded - and because a
tick that trades deliberately skips quote construction, the quotes were
never built. The result was a strategy that traded on every single tick
and never published a quote in its life.

Every simulation passed. The instruction-set simulator starts its
register file at zero, so `R9` happened to be zero and the guard
happened to work; all fourteen quoting tests were green. Real silicon
does not start at zero, and neither does a `CFG_RESTART`.

Two things came out of it. `fmma_sim.Cpu` now takes a `poison=`
argument that fills the register file with a non-zero value, and
`test_strategy.TestUninitialisedRegisters` runs both strategies from a
poisoned file - those tests fail on the unfixed program, which is the
only way to know a regression test is worth having. And
`Software/isa_probe.asm` exists so the next "the fabric is doing
something the model does not" question has a cheap answer; see
[15](15-troubleshooting.md).

### When it trades

```
market bid >= our ask   ->  we would be lifted  ->  SELL
market ask <= our bid   ->  we would be hit     ->  BUY
```

The check runs against the quotes computed on the **previous** tick, not
the current one. That is not an implementation detail, it is the whole
semantics of a resting order: quotes derived from the current mid sit
inside the current spread by construction, so a quote can only ever be
reached by a later market move. Checking against quotes from the same
tick would mean never trading at all - which is exactly the bug the
first version of this file had, and what
`test_first_tick_only_quotes` and `test_a_rise_lifts_our_ask` now guard.

A tick that trades leaves the quotes in place until the next one, which
is also what a desk does: you re-quote once the fill is known.

```
python Assembler.py market_maker.asm
sudo -E ./marketstream --half-spread 200 --skew 50 --max-pos 5
```

### What is still missing

This simulates resting quotes rather than resting them: the host sends a
*market* order when our price is reached. Real quoting needs resting
limit orders with cancel/replace, acknowledgement tracking and an order
lifecycle state machine - and a broker API that can cancel and replace
in microseconds, which a REST endpoint at tens of milliseconds cannot.

So the honest description of the system remains: **a latency-optimised
decision engine with a market-making memory map, running either a
mean-reversion trigger or a simulated two-sided quote.**
[16](16-project-plan.md) tracks the rest.

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
