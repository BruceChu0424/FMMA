# 9. Risk management

## 9.1 Principle

Every control that can stop a trade is **in the fabric, on the decision
path**. None of them depends on the host behaving correctly.

That is deliberate. The host is the complicated, failure-prone half: it runs
an operating system, terminates TLS, parses JSON from the internet and can be
killed, paused or starved. If the position limit lived there, then a bug in
the JSON parser could produce an unlimited position. Putting the limit in the
CPU means the worst a broken host can do is publish bad prices — and the
engine will still refuse to exceed the limit it was given.

The host keeps a rate limiter of its own, but that protects the broker's API,
not the account.

## 9.2 Controls

| Control | Where | Enforced by | Effect |
|---------|-------|-------------|--------|
| Position limit | fabric | `CFG_MAX_POS`, checked before every signal | inventory cannot exceed ±N lots |
| Master switch | fabric | `CFG_ENABLE`, checked before the position limit | no signal is published at all |
| Hardware reset | board | `KEY[0]` | the engine stops and restarts from a known state |
| Software restart | fabric | `CFG_RESTART` | the engine restarts without touching the board |
| Order cooldown | host | `--cooldown`, default 1 s | bursts are spaced out |
| Loss limit | host | `--max-loss`, 0 = off | stops trading and disables the fabric past a realised+unrealised loss |
| Stale-feed watchdog | host | `--stale-feed`, default 60 s | suppresses orders while market data is not arriving |
| Dry run | host | `--dry-run` | decisions are logged, nothing is sent |
| Fixed order size | host | `--qty`, default 0.001 BTC | one signal can only ever move one lot |
| Price range clamp | host | `FMMA_PRICE_MAX` | a malformed quote cannot invert the comparisons |
| Version gate | both | `FW_VERSION` + datapath probe | a program/bitstream mismatch stops the chain before it trades |
| Paper trading only | account | Alpaca paper endpoint | no real capital, ever |

## 9.3 The position limit

The check sits between the decision and the publication:

```
DO_BUY:                              DO_SELL:
    ...enable check...                   ...enable check...
    LDI  R4, #CFG_MAX_POS                LDI  R4, #CFG_MAX_POS
    LOAD R8, R4                          LOAD R8, R4
    CMP  R13, R8                         XOR  R10, R10
    BLT  BUY_ALLOWED                     SUB  R10, R8        ; -MAX_POS
    BUC  RISK_BLOCK                      CMP  R10, R13
                                         BLT  SELL_ALLOWED
                                         BUC  RISK_BLOCK
```

A buy is allowed while `position < +MAX_POS`; a sell while
`−MAX_POS < position`. At exactly the limit the reducing side is still
allowed, which is the behaviour you want — a limit that blocks the trade that
would flatten you is a trap.

Suppressed decisions are not silent. `REJECTS` counts them and `STATUS` says
why, so the host can see that the strategy wanted to trade and was not
permitted to. A rising `REJECTS` with a flat position means the limit is too
tight for the threshold.

Verified by `test_strategy.TestRiskLimits` (six cases, including both
just-inside-the-limit and reduce-while-at-the-limit) and `tb_fmma` steps
9–10 on real RTL.

## 9.4 Inventory is a shared number

A position limit is only as good as the position. The host places the orders,
so it is the authority; the CPU enforces the limit, so it needs the same
number. Three mechanisms keep them together:

1. **Fill reports.** Every accepted order is reported to the CPU with
   `FILL_SIDE`/`FILL_QTY`/`FILL_SEQ`, and the CPU applies it exactly once.
2. **`CFG_POSITION` on startup.** The CPU adopts the host's figure rather
   than assuming zero. Restarting a strategy must not make it forget a
   position that exists at the broker —
   `test_inventory_is_adopted_from_the_hps_not_zeroed` checks that the limit
   is respected immediately after a restart.
3. **`POSITION` published back.** The host can compare the CPU's view against
   its own and against the broker's, and the statistics line prints it.

## 9.5 The kill switches

Three, in increasing severity:

| Action | Stops | Leaves running | Recovery |
|--------|-------|----------------|----------|
| `CFG_ENABLE = 0` | new signals | the engine, the heartbeat, `REJECTS` | write 1 |
| `CFG_RESTART = 1` | everything; state is re-initialised | the engine | automatic |
| `KEY[0]` | the CPU entirely | nothing | release the button |

`CFG_ENABLE = 0` is the one to reach for first: the engine keeps consuming
quotes and counting the trades it *would* have made, which is exactly what
you want while diagnosing something. Ctrl-C on the host also sets it, so
killing the program stops the engine trading rather than leaving it armed.

## 9.5a P&L and the loss limit

`fmma_risk.c` keeps average-cost inventory accounting on the host:
adding to a position moves the average, reducing it realises the
difference against that average, and crossing through zero does both.
`fmma_risk_mark` marks the remaining position against the current mid.

```
--max-loss 5000      # stop trading at a 50.00 loss (price units)
```

When realised plus unrealised loss reaches the limit, the host halts:
it stops sending orders **and** writes `CFG_ENABLE = 0`, so the fabric
stops signalling too. The halt is sticky - it needs a restart, not a
recovery in price - because a limit that un-trips itself is not a limit.

This is the one control that has to be on the host: the fabric has no
notion of money and no price history to mark against.
`test_units.c` covers the accounting (both directions, averaging in,
crossing through zero) and the limit.

## 9.5b The stale-feed watchdog

If the feed dies, the CPU keeps its anchor and simply never sees another
quote, so it never trades - safe, but silent. The host now notices:
after `--stale-feed` milliseconds without a tick it logs once and
`fmma_risk_check` suppresses orders until data resumes. That matters
because a decision computed from a quote a minute old is not a decision
worth acting on.

## 9.6 What is not protected

Stated plainly, because a risk document that only lists what it does is
worse than none.

| Not protected | Why, and what would fix it |
|---------------|----------------------------|
| **Fractional fills** | The protocol carries inventory in whole lots, so a partially filled order is still reported as one lot. `fmma_exec` reads `filled_qty` and warns when it is zero, but anything between 0 and 1 would need a fractional inventory field. |
| **Fill price accuracy** | The host uses the broker's `filled_avg_price` when it supplies one and the mid at submission otherwise, so P&L on a fill without a reported price is approximate. |
| **Fat-finger prices** | The clamp stops arithmetic overflow, not a quote that is wrong but in range. A sanity band around the previous mid would. |
| **Host death mid-order** | If the process dies after the POST and before the fill report, the CPU's inventory is stale until the next restart supplies `CFG_POSITION`. Querying the broker's position at startup would close this; the hook (`--position`) exists, the query does not. |
| **Multiple instances** | Nothing stops two copies of the host program driving the same board. The second would corrupt the first's sequence numbers. A lock file would. |

## 9.7 Operating limits

Recommended settings for a demonstration:

| Setting | Value | Reason |
|---------|-------|--------|
| `--max-pos` | 3–5 | small enough that a runaway is visibly bounded |
| `--qty` | 0.001 | the smallest size Alpaca accepts for BTC |
| `--threshold` | 1000 (= $10) | roughly a handful of trades an hour on BTC |
| `--cooldown` | 1000 ms | keeps well inside Alpaca's rate limit |
| Account | paper only | see [18](18-security-and-compliance.md) |

Maximum exposure is bounded by construction: `max-pos × qty` = 5 × 0.001 BTC
≈ 0.005 BTC of notional, on a paper account, and the engine physically cannot
signal past it.

## 9.8 Verification

| Control | Test |
|---------|------|
| long limit blocks a buy | `tb_fmma` step 9, `test_buy_blocked_at_the_long_limit` |
| short limit blocks a sell | `test_sell_blocked_at_the_short_limit` |
| reducing is allowed at the limit | `tb_fmma` step 10, `test_selling_is_still_allowed_while_long` |
| just inside the limit is allowed | `test_just_inside_the_limit_is_allowed` |
| the master switch suppresses everything | `tb_fmma` step 11, `test_disable_switch_suppresses_everything` |
| the switch outranks the risk check | asserted by `tb_fmma` step 11's `STATUS` check |
| re-enabling resumes trading | `test_re_enabling_resumes_trading` |
| rejects are counted and reported | `tb_fmma` step 9 |
| fills move the inventory both ways | `tb_fmma` step 8, `TestFillAccounting` |
| a fill is applied exactly once | `test_a_fill_is_applied_once` |
| inventory survives a restart | `test_inventory_is_adopted_from_the_hps_not_zeroed` |
| hardware reset works | `tb_fmma` step 14 |
