# 7. Shared memory protocol

**Protocol version 2.** This is the contract between the ARM host and the CPU
in the fabric. Both sides must agree on every item here, so neither side owns
the table: it is generated from
[`../Software/protocol.py`](../Software/protocol.py) into

* `Software/fmma_protocol.h` — for the host application
* `Software/fmma_protocol.inc` — for `trading.asm`
* `Testbenches/fmma_protocol.vh` — for the testbenches

`make protocol` regenerates all three; `make check-generated` fails if any of
them has drifted. Editing them by hand is the one thing guaranteed to break
the system quietly.

## 7.1 Transport

| Item | Value |
|------|-------|
| Medium | 4 KB dual-port on-chip RAM (`onchip_memory2_0` in the Qsys system `HPSfgpa2`) |
| Host port | `s1`, on the HPS lightweight AXI master |
| Host mapping | `mmap("/dev/mem", 0xFF200000, 4096)`, indexed as `volatile unsigned int[]` |
| CPU port | `s2`, exported as `fpga_bram_s2`, word addressed, 1024 × 32 |
| Clock | both ports on `CLOCK_50`; the bridge runs at 50 MHz too, so there is no clock-domain crossing |
| Read latency | one cycle (address registered, output combinational) |
| Read during write, mixed ports | **`OLD_DATA`** — see §7.6, this is load-bearing |

All indices below are **32-bit word indices**. Byte offset = 4 × word index.

## 7.2 Memory map

| Word | Byte offset | Name | Direction | Meaning |
|-----:|------------:|------|-----------|---------|
| 0-7 | 0x000 | reserved | - | Must stay zero. A zero word is the CPU's HALT instruction. |
| 8-255 | 0x020 | program | HPS -> FPGA | CPU program image, written once by the loader. |
| 256 | 0x400 | `TICK_SEQ` | HPS -> FPGA | Seqlock counter for the market-data block. The HPS makes it odd before touching BID/ASK/BID_SIZE/ASK_SIZE and even again afterwards, so the CPU can tell a consistent snapshot from a half-written one. |
| 257 | 0x404 | `BID` | HPS -> FPGA | Best bid price, in cents (price x FMMA_PRICE_SCALE). |
| 258 | 0x408 | `ASK` | HPS -> FPGA | Best ask price, in cents (price x FMMA_PRICE_SCALE). |
| 259 | 0x40C | `BID_SIZE` | HPS -> FPGA | Size resting at the bid, x 10000 (0.0001 lot resolution). |
| 260 | 0x410 | `ASK_SIZE` | HPS -> FPGA | Size resting at the ask, x 10000 (0.0001 lot resolution). |
| 261 | 0x414 | `CFG_THRESH` | HPS -> FPGA | Mean-reversion trigger distance in price units (cents). 1000 = $10.00. |
| 262 | 0x418 | `CFG_MAX_POS` | HPS -> FPGA | Risk limit: the largest absolute inventory the CPU may signal itself into, in lots. |
| 263 | 0x41C | `CFG_ENABLE` | HPS -> FPGA | Master switch. 0 suppresses every signal (the CPU keeps running and counting rejects); 1 trades normally. |
| 264 | 0x420 | `CFG_HALF_SPREAD` | HPS -> FPGA | Quoting strategy: half the spread the CPU quotes around the mid, in price units. |
| 265 | 0x424 | `CFG_SKEW` | HPS -> FPGA | Quoting strategy: how far to shift both quotes per lot of inventory, in price units. Leaning against the position. |
| 266 | 0x428 | `CFG_RESTART` | HPS -> FPGA | Write non-zero to make the CPU jump back to the top of its program: counters, anchors and the inventory are re-initialised and the output block is cleared. The CPU clears this word when it acts on it. There is no reset line from the HPS to the fabric, so this is how the loader restarts a strategy it has just rewritten. Deliberately adjacent to FILL_SEQ so the CPU can reach both from one address register. |
| 267 | 0x42C | `FILL_SEQ` | HPS -> FPGA | Publish counter for fill reports. The HPS writes FILL_SIDE and FILL_QTY first, then increments this. |
| 268 | 0x430 | `FILL_SIDE` | HPS -> FPGA | 1 = the HPS bought for us, 2 = it sold. |
| 269 | 0x434 | `FILL_QTY` | HPS -> FPGA | Size of the reported fill, in lots. |
| 270 | 0x438 | `CFG_POSITION` | HPS -> FPGA | The inventory the CPU should start from, in lots, signed. Read during initialisation and on every CFG_RESTART. Restarting the strategy must not make the CPU forget a position that really exists at the broker, or the risk limit would let it double up; the HPS is the authority on the real position and states it here. |
| 320 | 0x500 | `HEARTBEAT` | FPGA -> HPS | Incremented once per strategy loop. Proof the CPU is alive, and the basis for measuring the loop rate from the HPS side. |
| 321 | 0x504 | `SIGNAL` | FPGA -> HPS | The trade decision: 1 = buy, 2 = sell. |
| 322 | 0x508 | `SIGNAL_TICK` | FPGA -> HPS | The TICK_SEQ value the decision was computed from. Lets the HPS attribute a signal to the market message that caused it, which is how end-to-end latency is measured. |
| 323 | 0x50C | `SIGNAL_SEQ` | FPGA -> HPS | Incremented after SIGNAL and SIGNAL_TICK are valid. The HPS edge-detects this word; it never writes it, so no signal can be lost by a clear that races the CPU. |
| 324 | 0x510 | `POSITION` | FPGA -> HPS | Inventory in lots, as a signed 32-bit value. Maintained by the CPU from the fill reports. |
| 325 | 0x514 | `STATUS` | FPGA -> HPS | Bit 0 running, bit 1 reserved, bit 2 last decision blocked by the risk limit, bit 3 last decision suppressed by CFG_ENABLE. Bits 2 and 3 both describe **the most recently evaluated quote**, not the current configuration — see §7.3. |
| 326 | 0x518 | `REJECTS` | FPGA -> HPS | Count of decisions the CPU suppressed because of the position limit or CFG_ENABLE. |
| 327 | 0x51C | `FW_VERSION` | FPGA -> HPS | Protocol version the running CPU program implements, published only after the datapath probe passes. The HPS refuses to trade if this does not match. |
| 328 | 0x520 | `QUOTE_BID` | FPGA -> HPS | Quoting strategy: the bid the CPU would show, in cents. |
| 329 | 0x524 | `QUOTE_ASK` | FPGA -> HPS | Quoting strategy: the ask the CPU would show, in cents. |
| 384-1023 | 0x600 | free | - | Unused; room for an order book. |

## 7.3 Direction is enforced, not just documented

The host writes **only** words 0–319 and reads only 320–383. The CPU writes
**only** words 320–383 and reads only 0–319, plus its own program area.

This is not a stylistic rule. Both RAM ports can write, and if they ever
write the same word in the same cycle the hardware result is undefined —
there is no arbitration. Keeping the two write sets disjoint makes that
impossible by construction.

The testbench checks it: `HPSfgpa2_stub.v` counts same-address write
collisions and `tb_fmma` step 15 asserts the count is zero after running the
whole scenario.

### A consequence worth knowing: `STATUS` lags

Because the CPU is the only writer of `STATUS` and it writes it on the
decision path, **`STATUS` describes the last quote the CPU evaluated,
not the current configuration.** Disable trading in a quiet market and
`STATUS` keeps reporting the previous state until the next quote
arrives.

This is deliberate. Re-publishing `STATUS` from the idle loop would add
four to six instructions to a thirteen-instruction loop — a 40 % worse
staleness bound and decision latency
([14](14-latency-and-performance.md)) — to echo back a setting the host
wrote itself and can read from `CFG_ENABLE` at any time.

So:

* **`CFG_ENABLE` is authoritative** for "is trading currently allowed".
  `fmma-probe` prints it alongside `STATUS` for exactly this reason.
* **`STATUS` is evidence** that the CPU saw the setting and acted on it.
* The suppression itself is immediate — the very next quote is
  suppressed and counted in `REJECTS`. Only the report lags.

`fmma-bench --selftest` checks this the right way round: it publishes a
quote after disabling and then asserts both that nothing was decided
and that `STATUS` reports it.

## 7.4 Boot

The on-chip RAM is configured with no initialisation file, so it powers up
zeroed, and a zero word is the CPU's HALT instruction. That makes the boot
sequence fall out for free:

1. After configuration the CPU sits at word 8, polling it once per clock.
   `HEX0` shows a steady `8`.
2. The loader writes the program image **with the entry word last**. Until
   that write lands the CPU still sees zero and stays parked, so it cannot
   execute a partially written image.
3. The loader writes `CFG_RESTART = 1`.
4. The CPU runs its initialisation block, probes the datapath (see
   [04](04-isa-reference.md) §4.8) and publishes `FW_VERSION`.
5. The loader waits for `FW_VERSION` to match and the heartbeat to move
   before it sets `CFG_ENABLE = 1`.

If a previous program is already running, step 2 is still safe because
trading is disabled first, and step 3 brings the old program back to the top
of the new image. If the CPU is wedged badly enough not to poll
`CFG_RESTART`, `KEY[0]` on the board is the way out.

## 7.5 Market data: a seqlock

The host writes four words that have to be read as one snapshot, while the
CPU reads them, with no lock between the two.

**Writer (host), `publish_tick`:**

```c
fpga[TICK_SEQ] = seq + 1;          /* odd: do not read this */
barrier();
fpga[BID] = bid;  fpga[ASK] = ask;
fpga[BID_SIZE] = bsz;  fpga[ASK_SIZE] = asz;
barrier();
fpga[TICK_SEQ] = seq + 2;          /* even: the snapshot is consistent */
```

**Reader (CPU), in `trading.asm`:**

```
    LOAD R7, R2          ; s1 = TICK_SEQ
    CMP  R7, R11
    BEQ  LOOP            ; nothing new
    MOV  R8, R7
    AND  R8, R1
    CMP  R8, R0
    BNE  LOOP            ; odd -> a write is in progress, come back
    ...read BID and ASK...
    LOAD R8, R2          ; s2 = TICK_SEQ again
    CMP  R8, R7
    BNE  LOOP            ; it moved -> the snapshot is torn, come back
    MOV  R11, R7         ; commit
```

A snapshot is accepted only if the sequence number was even before the read
and unchanged after it. Any write that overlaps the read changes the number,
and the CPU simply comes round again 780 ns later — the feed produces a quote
every couple of hundred milliseconds, so a retry costs nothing.

`tb_fmma` step 12 verifies both halves: a quote left half-published (odd
sequence) is not acted on, and the same quote once completed is.
`test_strategy.test_torn_snapshot_is_retried_not_used` covers the harder
case, where a second quote lands *during* the read; the discriminator is
`SIGNAL_TICK`, which must name the new quote rather than the old one.

## 7.6 Why `OLD_DATA` matters

The on-chip RAM used to be generated with
`read_during_write_mode_mixed_ports = "DONT_CARE"`. Under that setting a read
of a word the other port is writing in the same cycle returns *indeterminate*
data — the vendor simulation model drives X, and silicon gives you whatever
the sense amplifiers settle on.

That breaks the seqlock at its root, because the sequence number itself is a
word the host writes and the CPU reads. It also breaks the plain data reads:
with a ~780 ns loop, each host write has roughly a 1-in-39 chance of landing
on the same cycle as a CPU read of that word, and a corrupted price is a
trade on a number that never existed.

The RAM is now configured `OLD_DATA`, which Cyclone V M10K supports for
same-clock true-dual-port operation and which returns the previous contents.
Every concurrent access then has a defined answer, and the seqlock's "did the
sequence number move?" test does the rest. The change is in
`Software/HPSfgpa2.qsys` and in the generated
`HPSfgpa2_onchip_memory2_0.v`; [10](10-build-guide.md) §10.6 explains why
both had to be edited.

## 7.7 Decisions: publish last, never clear

The CPU writes `SIGNAL` and `SIGNAL_TICK` and only then increments
`SIGNAL_SEQ`. The host edge-detects `SIGNAL_SEQ`; because the sequence number
is written last, seeing a new value guarantees the words it describes are
already in memory.

**The host never writes into the output block.** That is the whole trick.

Protocol version 1 had the host clear `SIGNAL` back to zero after acting on
it, which created two faults at once: a decision the CPU raised between the
host's read and the host's clear was destroyed, and a decision that persisted
across two polls was executed twice. Neither is visible in a demo, and both
cost money. With a monotonically increasing counter the host can also tell
how many decisions it missed — `poll_fpga` reports that as
`"N signal(s) arrived faster than this loop could read them"`.

## 7.8 Fills

Inventory has to be the same number on both sides or the risk limit is
meaningless. The host owns the truth, because it is what talks to the broker,
and reports each fill using the same publish-last pattern:

```c
fpga[FILL_SIDE] = side;  fpga[FILL_QTY] = qty;
barrier();
fpga[FILL_SEQ] = ++seq;            /* published last */
```

The CPU applies a fill once, when `FILL_SEQ` changes, and republishes its
inventory in `POSITION`. On restart it *adopts* `CFG_POSITION` rather than
zeroing, and it takes the current `FILL_SEQ` as already-seen so that a fill
reported before the restart is not applied a second time.

## 7.9 Configuration

`CFG_THRESH`, `CFG_MAX_POS`, `CFG_ENABLE` and `CFG_POSITION` are read by the
CPU at run time, so the strategy can be retuned without reassembling
anything, let alone rebuilding the bitstream. `CFG_ENABLE` is the kill
switch: with it at zero the CPU keeps running, keeps consuming quotes and
keeps counting what it *would* have done in `REJECTS`, but publishes nothing.

`CFG_HALF_SPREAD` and `CFG_SKEW` are reserved for the two-sided quoting
strategy sketched in [08](08-trading-strategy.md) §8.6; `trading.asm` does
not read them, and `QUOTE_BID`/`QUOTE_ASK` stay zero.

## 7.10 Ordering and barriers

The seqlock and the publish-last pattern are both about *store order*, so
both sides have to stop their toolchain reordering the stores.

On the host: the window is mapped from `/dev/mem` with `O_SYNC`, which gives
device memory that the ARM core does not reorder, and `fmma_barrier()`
(`__sync_synchronize()`) stops the compiler doing it instead. The pointer is
`volatile`, so no access is elided.

On the CPU there is nothing to do: it is in-order, single-issue, and has no
store buffer.

## 7.11 Numeric ranges

| Quantity | Scale | Range the CPU can handle | Why |
|----------|-------|--------------------------|-----|
| Price | cents (×100) | 0 … 1,073,741,823 ($10.7 M) | the strategy adds bid and ask, and the sum must stay positive in signed 32-bit |
| Size | ×10000 | 0 … 429,496 lots | unsigned; not used in arithmetic |
| Position | lots | ±2,147,483,647 | signed |
| Sequence numbers | — | wrap at 2³² | both sides only ever compare for equality, so wrapping is harmless |

the host application clamps prices to the range above and logs when it does,
rather than letting a bad quote wrap into the sign bit. Version 1 scaled
prices by 10,000 with no clamp, which put BTC's sum-of-bid-and-ask about 7 %
below the point where every comparison inverts.

## 7.12 Migration from version 1

| v1 | v2 |
|----|----|
| words 64–69, flat | words 256+ (inputs) and 320+ (outputs), disjoint |
| price × 10000 | price × 100 (cents), with a range clamp |
| last trade price, buy side and sell side | true best bid and best ask, from the `ticker` channel |
| no consistency mechanism | seqlock in, publish-last out |
| host clears `SIGNAL` | host never writes the output block |
| no inventory, no limits | `POSITION`, `CFG_MAX_POS`, `REJECTS`, `STATUS` |
| no way to restart | `CFG_RESTART`, plus `KEY[0]` in hardware |
| no version check | `FW_VERSION`, gated on a datapath probe |

The two versions are not interoperable, which is what `FW_VERSION` is for.
