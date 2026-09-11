# 6. HPS software design

The host side runs on the DE1-SoC's ARM Cortex-A9 under Linux: one
process, one thread, one event loop, about 2,000 lines across thirteen
modules.

## 6.1 What it is and is not responsible for

| It does | It does not |
|---------|-------------|
| terminate TLS, speak WebSocket and HTTP | decide anything about trading |
| parse quotes into exact fixed point | compute a mid, a band or a position limit |
| load the CPU program and start the engine | run the strategy (except in `--no-fpga` mode) |
| publish quotes through the seqlock | write into the FPGA's output block |
| execute the fabric's decisions as orders | invent decisions of its own |
| follow orders to a terminal state and report fills | |
| track P&L and enforce a loss limit | |
| measure latency and report it | |

The one deliberate exception is `--no-fpga`, which runs a C
transcription of the same strategy so the two can be compared. §6.9.

## 6.2 Module map

Each file does one thing, and the dependency arrows all point the same
way: nothing below knows about anything above it.

```
  main.c              start, stop, exit codes
    └── fmma_app      the event loop; the only file that knows the whole shape
          ├── fmma_config    defaults, environment, command line
          ├── fmma_feed      Coinbase WebSocket -> struct fmma_quote
          ├── fmma_fpga      the host half of the shared-memory protocol
          │     └── fmma_socfpga   "is the fabric configured?" - the safety gate
          ├── fmma_exec      orders, order status, fills
          ├── fmma_risk      inventory, P&L, loss limit, stale-feed watchdog
          ├── fmma_strategy  the software reference strategy
          └── fmma_stats     counters and the latency histogram
   shared: fmma_log, fmma_time, fmma_fixed, fmma_json, fmma_tls
```

| File | Lines | Responsibility |
|------|------:|----------------|
| `src/main.c` | ~60 | argument parsing, signals, exit codes |
| `src/fmma_app.c` | ~250 | wiring and the event loop |
| `src/fmma_config.c` | ~180 | one struct of defaults, one argument table |
| `src/fmma_feed.c` | ~200 | WebSocket client, subscription, reconnect |
| `src/fmma_fpga.c` | ~280 | seqlock, loader, signal polling, fill reports |
| `src/fmma_socfpga.c` | ~80 | the fabric-state check (§6.4) |
| `src/fmma_exec.c` | ~330 | order submission and status polling |
| `src/fmma_risk.c` | ~130 | average-cost P&L, limits |
| `src/fmma_strategy.c` | ~70 | the strategy in C |
| `src/fmma_stats.c` | ~130 | counters, latency histogram, reporting |
| `src/fmma_fixed.c` | ~90 | decimal text <-> scaled integer |
| `src/fmma_json.c` | ~55 | field extraction |
| `src/fmma_tls.c` | ~60 | CA bundle, handshake |
| `src/fmma_log.c` | ~60 | leveled, timestamped logging |
| `src/fmma_probe.c` | ~250 | a standalone diagnostic (§6.10) |

The split is not cosmetic. It is what lets `tests/test_units.c` exercise
the parsing, the strategy and the P&L on a laptop with no board, no
network and no root - which is where most of the bugs were found.

## 6.3 The event loop

```
main
 ├─ fmma_config_parse_args
 ├─ fmma_app_create
 │    ├─ fmma_fabric_check        refuse to touch the bridge unless safe
 │    ├─ fmma_fpga_open           mmap /dev/mem at 0xFF200000
 │    ├─ fmma_fpga_load           image with the entry word last, then restart
 │    └─ mg_mgr_init, feed, exec
 └─ fmma_app_run  (until SIGINT)
      ├─ mg_mgr_poll(poll_ms)
      │    ├─ feed    -> on_quote  -> publish_tick, then drain
      │    └─ exec    -> on_fill   -> risk + fabric
      ├─ drain_fpga        act even when the feed is quiet
      ├─ fmma_exec_poll    follow working orders
      ├─ fmma_feed_poll    reconnect if needed
      └─ report every --stats seconds
```

## 6.4 The safety gate

`fmma_socfpga.c` exists because of one specific failure, and it is worth
stating plainly because it cost this project a hung board.

On Cyclone V there is **no timeout on the HPS-to-FPGA bridge**. If the
fabric is unconfigured, a read of `0xFF200000` issues an AXI transaction
that never completes. The core that issued it blocks forever; in
practice the whole board stops responding and needs a power cycle. It
is not a signal you can catch and there is no software recovery.

So nothing maps the bridge without first asking the FPGA manager
whether the fabric is in user mode:

```c
if (fmma_fabric_check(cfg->force) != 0) return NULL;
```

The check is not a proof — the fabric can be in user mode running a
design with nothing at that address — but it removes the common case,
and `--force` makes the residual risk an explicit choice. For a first
bring-up of a new bitstream, confirm on `HEX0` first;
[11](11-board-bringup.md) §11.5 explains.

## 6.5 Market data

Coinbase Exchange WebSocket, **`ticker` channel**, which carries
`best_bid` and `best_ask` — real top-of-book quotes.

Version 1 subscribed to `matches`, which reports executed trades. Its
`side` field is the *maker* side, so the two words the old code called
`BUY_PRICE` and `SELL_PRICE` were the last taker-buy print and the last
taker-sell print — not a bid and an ask, and not a snapshot of
anything. The strategy's "crossed market" test compared them, which was
not a meaningful comparison. Moving to `ticker` is what makes the
strategy mean what it says.

Message dispatch matches the `type` field exactly, because
`strstr(json, "\"ticker\"")` also fires on the subscription
acknowledgement and `strstr(json, "\"match\"")` used to fire on
`last_match`.

The client reconnects on its own with exponential backoff (500 ms
doubling to 30 s, reset on a successful subscribe). Without that, one
dropped connection left the previous version running forever with a
healthy heartbeat and no data.

## 6.6 Parsing

`fmma_parse_scaled` converts decimal text to a scaled integer without
ever touching a float:

```c
fmma_parse_scaled("97431.02", 100)  ->  9743102
```

Version 1 used `strtof` and multiplied by 10,000. A `float` carries 24
bits of mantissa; a BTC price scaled by 10,000 needs 30, so the low six
bits were noise and the four decimal places the protocol advertised were
not the ones delivered. Integer parsing is exact, faster, and cannot
surprise anyone.

It stops at the first character that cannot belong to a number, so it is
safe on a pointer into the middle of a JSON document, and it saturates
rather than wrapping on an absurd integer part.

Prices are then clamped to `FMMA_PRICE_MAX` (2³⁰ − 1) and the clamp is
counted and logged. The fabric adds bid and ask, so each side must stay
below 2³⁰ for the sum to remain a positive signed 32-bit value; letting
a bad quote through would invert every comparison in the strategy.

## 6.7 Talking to the fabric

All of it is in [07-shared-memory-protocol](07-shared-memory-protocol.md);
`fmma_fpga.c` is the implementation:

| Function | Protocol role |
|----------|---------------|
| `fmma_fpga_publish_tick` | seqlock writer: odd, data, even |
| `fmma_fpga_report_fill` | publish-last fill report |
| `fmma_fpga_load` | image with the entry word last, full readback verify, restart, version check |
| `fmma_fpga_poll_signal` | edge-detect `SIGNAL_SEQ`; never writes the output block |
| `fmma_fpga_read_state` | heartbeat, position, status, rejects |
| `barrier()` | `__sync_synchronize()` around the order-critical stores |

`fmma_fpga_load` refuses to run if the assembled program's base does not
match the protocol's, or if the image would overrun the program area —
both were silent overwrites of the data block before.

`wait_for_cpu` distinguishes three outcomes rather than one: running, a
version mismatch, and *alive but refusing to declare a version*. The
third is the datapath probe failing, and it gets its own message telling
you to rebuild the bitstream ([04](04-isa-reference.md) §4.8).

## 6.8 Execution and fills

```
signal -> risk check -> cooldown -> dry run -> credentials
       -> POST /v2/orders -> follow to a terminal state -> report the fill
```

**Orders are followed, not assumed.** The previous version reported a
fill as soon as the POST returned 2xx, which conflates "the broker
accepted the order" with "the order executed". `fmma_exec.c` keeps up to
eight working orders, polls `GET /v2/orders/{id}` every
`--order-poll` ms, and only reports a fill when the status is `filled`
— using the broker's `filled_avg_price` when it gives one. An order
that does not reach a terminal state within 60 s is abandoned with a
warning rather than polled forever.

This matters because the fabric's position limit is only as good as the
position, and the position is only right if a fill report means a fill.

## 6.9 The software reference strategy

`--no-fpga` runs `fmma_strategy.c`, a transcription of `trading.asm`,
and lets this CPU decide. `--bench` runs it *alongside* the fabric on a
throwaway copy of the state and times it with `CLOCK_MONOTONIC`.

The comparison is deliberately narrow: it times the arithmetic only, not
the bus traffic, because bus traffic is not something an FPGA removes.
[14](14-latency-and-performance.md) §14.5 has the numbers and the honest
reading of them.

`--no-fpga` also makes the whole program runnable on a laptop, which is
how the feed and the broker path were developed without a board.

## 6.10 The probe

`fmma-probe` is a separate, tiny program that depends on nothing but
libc. It builds in a second on the board and works before the main
application does, which makes it the right first thing to run during
bring-up and the right first thing to reach for when something is wrong.

```
fmma-probe             summarise the protocol block
fmma-probe watch       follow the heartbeat, position and signals
fmma-probe ramtest     prove the window really is our shared RAM
fmma-probe dump [n]    hex dump
fmma-probe read/write  poke individual words
```

`ramtest` is the useful one: it writes unique values and walking ones
into the free region above the protocol block and reads them back. A
PIO register block — which is what the stock DE1-SoC reference design
puts at this address — fails it immediately, so it answers "is *our*
design in the fabric?" without needing to see the board.

## 6.11 Operational behaviour

| Concern | Behaviour |
|---------|-----------|
| Credentials | `APCA_API_KEY_ID` / `APCA_API_SECRET_KEY` from the environment only. Never a literal, never logged, never in a config dump. |
| TLS trust | A real CA bundle from the system, or `--ca`. Warns loudly if none is found. Version 1 passed an empty CA, which verifies nothing. |
| Shutdown | `SIGINT`/`SIGTERM` set a flag; the loop exits, disables trading in the fabric, prints final statistics, unmaps and closes. |
| `SIGPIPE` | ignored, so a dropped socket cannot kill the process |
| Failure to start | Distinct exit codes: 1 arguments, 2 fabric, 3 CPU |
| Logging | Leveled and timestamped, line buffered, so a redirected log survives a kill |

## 6.12 Build

Two settings are not negotiable and both cost real time to discover;
they are documented in the Makefile and in [10](10-build-guide.md) §10.3:
**`-std=gnu99`** (the DE1-SoC images in circulation carry gcc 4.6, which
has no C11 mode at all) and **`-DMG_TLS=MG_TLS_OPENSSL`** (the built-in
TLS stack cannot complete a handshake with Coinbase).

`make static` produces a self-contained binary for a board whose
distribution is too old to install `libssl-dev`.
