# 6. HPS software design

[`../Software/MarketStream.c`](../Software/MarketStream.c) is the whole host
side: one process, one thread, one event loop. It runs on the DE1-SoC's ARM
Cortex-A9 under Linux.

## 6.1 Responsibilities

| It does | It does not |
|---------|-------------|
| terminate TLS and speak WebSocket and HTTP | decide anything about trading |
| parse quotes into fixed point | compute a mid, a band or a position limit |
| load the CPU program and start the engine | run the strategy (except in `--no-fpga` mode) |
| publish quotes through the seqlock | write into the FPGA's output block |
| execute the CPU's decisions as orders | invent decisions of its own |
| report fills back so inventory agrees | |
| measure and report latency | |

The one deliberate exception is `--no-fpga`, which runs a C transcription of
the same strategy so the two can be compared. §6.8.

## 6.2 Structure

```
main
 ├─ parse_args, getenv for credentials
 ├─ map_bridge            mmap /dev/mem at 0xFF200000
 ├─ load_fpga_program     image with the entry word last (docs/07 §7.4)
 ├─ start_cpu             CFG_RESTART, wait for FW_VERSION + heartbeat
 ├─ mg_mgr_init, connect_feed
 └─ loop until SIGINT
      ├─ mg_mgr_poll(poll_ms)
      │    └─ coinbase_cb  → handle_ticker → publish_tick → poll_fpga
      │    └─ alpaca_cb    → check status  → report_fill
      ├─ poll_fpga         (again, so a quiet feed does not delay a decision)
      ├─ reconnect if the feed dropped and the backoff has expired
      └─ print_stats every --stats seconds
```

## 6.3 Feed

Coinbase Exchange WebSocket, **`ticker` channel**, which carries `best_bid`
and `best_ask` — genuine top-of-book quotes.

Version 1 subscribed to `matches`, which reports executed trades. Its `side`
field is the *maker* side, so the two words the old code called `BUY_PRICE`
and `SELL_PRICE` were the last taker-buy print and the last taker-sell print
— not a bid and an ask, and not a snapshot of anything. The strategy's
"crossed market" test compared them, which was not a meaningful comparison.
Moving to `ticker` is what makes the strategy mean what it says.

Message dispatch matches on the `type` field rather than a substring:
`strstr(json, "\"ticker\"")` would also fire on the subscription
confirmation, and `strstr(json, "\"match\"")` used to fire on `last_match`.

### Reconnection

`mg_ws_connect` is not a one-shot at startup any more. `MG_EV_CLOSE` and
`MG_EV_ERROR` schedule a reconnect with exponential backoff (500 ms doubling
to a 30 s ceiling, reset on a successful subscribe). Without that, a single
dropped connection left the previous version running forever with a heartbeat
and no data.

## 6.4 Parsing

`parse_scaled` converts a decimal string to a scaled integer without a float:

```c
parse_scaled("97432.17", 100)  ->  9743217
```

Version 1 used `strtof` and multiplied by 10,000. A `float` has 24 bits of
mantissa; a BTC price scaled by 10,000 needs 30, so the low six bits were
noise and the four decimal places the protocol advertised were not actually
delivered. Integer parsing is exact, cheaper, and cannot surprise anyone.

Sizes are parsed the same way with a scale of 10,000, so fractional sizes
survive. The old code cast the float size to `unsigned`, which truncated
every realistic BTC size (0.0013 BTC) to zero.

Prices are clamped to `FMMA_PRICE_MAX` (2³⁰ − 1) and the clamp is logged.
The CPU adds bid and ask, so each side has to stay below 2³⁰ for the sum to
remain a positive signed 32-bit value; letting a bad quote through would
invert every comparison in the strategy.

## 6.5 Talking to the FPGA

All of it is in [07-shared-memory-protocol](07-shared-memory-protocol.md);
the functions that implement it are:

| Function | Protocol role |
|----------|---------------|
| `publish_tick` | seqlock writer: odd, data, even |
| `report_fill` | publish-last fill report |
| `push_config` | threshold, position limit, starting inventory |
| `load_fpga_program` | image with the entry word last, then full readback verify |
| `start_cpu` | `CFG_RESTART`, then wait for `FW_VERSION` and a moving heartbeat |
| `poll_fpga` | edge-detect `SIGNAL_SEQ`, attribute latency, execute |
| `fmma_barrier` | `__sync_synchronize()` around the ordering-critical stores |

`load_fpga_program` refuses to run if the assembled program's base does not
match the protocol's, or if the image would run past the program area. Both
of those used to be silent overwrites of the data block.

`start_cpu` distinguishes three outcomes instead of one: running, version
mismatch (the bitstream is older or newer than the program — see
[04](04-isa-reference.md) §4.8), and no heartbeat at all. The third prints
what to check, including pressing `KEY[0]`.

## 6.6 Order execution

```
signal → cooldown check → dry-run check → credentials check
       → POST /v2/orders → status check → report_fill
```

* **The HTTP status is checked.** A 2xx logs the round-trip time and reports
  a fill; anything else logs the broker's body and counts a rejection.
  Version 1 printed the response and moved on, so a rejected order was
  indistinguishable from a filled one and the FPGA's inventory drifted away
  from reality.
* **Fills are reported on acceptance.** Alpaca paper market orders are
  accepted and filled effectively immediately, so "accepted" is treated as
  "filled, one lot". [09](09-risk-management.md) §9.6 says what a system
  that had to handle partial fills would do instead.
* **A cooldown** (`--cooldown`, default 1000 ms) rate-limits bursts. It is a
  protection against the broker's rate limits, not a risk control; the risk
  control is in the fabric.
* Per-order context is heap-allocated and freed in `MG_EV_CLOSE`, so a
  connection that errors out does not leak.

## 6.7 Latency measurement

Every published tick's timestamp is stored in a 256-entry ring indexed by its
sequence number. When a signal arrives, `SIGNAL_TICK` names the quote that
caused it, so the host can subtract:

```
latency = now  -  g_tick_time_us[SIGNAL_TICK % 256]
```

That is "from the moment the quote became visible to the fabric, to the
moment this program noticed the answer". It therefore includes the host's own
polling interval, which is why `--poll-ms` defaults to 1 and why
[14](14-latency-and-performance.md) reports the fabric-only figure from
simulation separately. Min, mean and max are printed every `--stats`
seconds.

This is the mechanism that closes requirement FR-14 and work items 9 and 14
of the original project plan.

## 6.8 The software reference strategy

`--no-fpga` runs `software_decide`, a C transcription of `trading.asm`, and
uses this CPU for the decision instead of the fabric. `--bench` runs it
*alongside* the fabric and times it with `CLOCK_MONOTONIC`.

The comparison is deliberately narrow and the document says so: it times the
arithmetic only, not the bus traffic, because bus traffic is not something an
FPGA removes. See [14](14-latency-and-performance.md) §14.5 for the numbers
and for why the honest headline is "deterministic", not "faster".

`--no-fpga` also makes the whole program runnable on a laptop with no board
and no root, which is how the feed and the Alpaca path were tested
independently of the hardware.

## 6.9 Operational behaviour

| Concern | Behaviour |
|---------|-----------|
| Credentials | `APCA_API_KEY_ID` / `APCA_API_SECRET_KEY` from the environment only. Never a literal, never a file in the tree. |
| TLS trust | A real CA bundle is loaded from `/etc/ssl/certs/ca-certificates.crt` (or `--ca`). Without one the program warns loudly. Version 1 passed an empty CA, which checks the host name and nothing else. |
| Shutdown | `SIGINT`/`SIGTERM` set a flag; the loop exits, disables trading on the FPGA, prints final statistics, unmaps and closes. Version 1 had an unreachable cleanup path. |
| Failure to load | Non-zero exit with a specific code (3 mmap, 4 loader, 5 CPU) rather than carrying on against unverified memory. |
| Logging | Line buffered, so a redirected log is complete if the process is killed. |

## 6.10 Command line

```
--no-fpga           run the software reference strategy instead of the fabric
--dry-run           never send an order; log what would have been sent
--bench             also time the software strategy, for comparison
--product ID        Coinbase product id            (default BTC-USD)
--symbol SYM        Alpaca symbol                  (default BTCUSD)
--qty Q             order size                     (default 0.001)
--threshold CENTS   move that triggers a decision  (default 1000 = $10.00)
--max-pos N         inventory limit in lots        (default 5)
--position N        inventory the CPU starts from  (default 0)
--cooldown MS       minimum spacing between orders (default 1000)
--poll-ms MS        network/FPGA poll interval     (default 1)
--stats SEC         statistics interval, 0 = off   (default 30)
--ca FILE           CA bundle for TLS              (default: autodetect)
-v, --verbose       print every quote
```

## 6.11 Build

The two settings that are not negotiable, both learned the hard way, are
documented in the Makefile itself and in [10](10-build-guide.md) §10.3:
`-std=gnu11` (not `c11`, which hides the POSIX declarations) and
`-DMG_TLS=MG_TLS_OPENSSL` (not the built-in stack, which cannot complete a
handshake with Coinbase).
