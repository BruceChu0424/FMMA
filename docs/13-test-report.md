# 13. Test report

Results for the revision this document is committed in. Every figure comes
from a command that is given next to it, and the tool output it was read
from is committed alongside, so any claim here can be checked against the
source in the same revision.

**Date:** 11 September 2026
**Machine:** BRUCE_T14P, Windows 11
**Toolchain:** Quartus Prime 25.1std.0 Build 1129 SC Lite, Icarus Verilog
12.0, Python 3.14, gcc 12.2 (Debian, in a container)

## 13.1 Summary

| Stage | Result |
|-------|--------|
| C: fixed point, JSON, strategy, P&L | **63 / 63 checks pass** |
| Python: ISA, assembler, simulator, both strategies | **96 / 96 pass** |
| RTL: ALU equivalence vs the golden model | **9,548 / 9,548 vectors pass** |
| RTL: full chain against the protocol | **31 / 31 assertions pass** |
| RTL: latency budget | **3 / 3 within budget** |
| Generated-file consistency | **pass** (cross-platform) |
| FPGA compile | **0 errors**, timing met |
| Host program compile | **0 errors, 0 warnings** under `-Wall -Wextra` |
| On-board validation | **not yet run** — [11](11-board-bringup.md) |

## 13.2 FPGA compile

```bash
quartus_sh --flow compile HFTTop
```

`Quartus Prime Full Compilation was successful. 0 errors, 433 warnings`
— about 48 minutes, almost all of it in the fitter.

### Resource usage

From `output_files/HFTTop.fit.summary`:

| Resource | Used | Available | % |
|----------|-----:|----------:|--:|
| Logic (ALMs) | 1,201 | 32,070 | 4 % |
| Registers | 1,133 | — | — |
| Pins | 46 | 457 | 10 % |
| Block memory | 32,768 bits | 4,065,280 | < 1 % |
| M10K blocks | 4 | 397 | 1 % |
| DSP blocks | 2 | 87 | 2 % |
| PLLs | 0 | 6 | 0 % |
| DLLs | 1 | 4 | 25 % |

Almost all of this is the HPS hard IP and its DDR3 interface; the CPU
itself is a small part of it. The four M10K blocks are the 4 KB shared RAM
and the two DSPs are the ALU's multiplier.

Logic usage **fell** from 1,652 ALMs (5 %) in the inherited design to 1,201
(4 %). The saving comes from the shift instructions: the old `LSH`/`ASH`
were written as unrolled loops that synthesised into two cascaded shifters,
and replacing them with a single signed-amount barrel shifter removed the
second one — while also making them produce the right answer
([CHANGELOG](../CHANGELOG.md)).

Splitting the top level into `cpu_core` and `reset_ctrl` cost exactly one
ALM (1,200 → 1,201), which is the expected result for a pure refactor and
is the cheapest available confirmation that it was one.

### Timing

From `output_files/HFTTop.sta.summary`, slow 1100 mV 85 °C corner:

| Check | Slack | TNS |
|-------|------:|----:|
| Setup `clk50` | **+2.401 ns** | 0.000 |
| Hold `clk50` | **+0.239 ns** | 0.000 |
| Setup `clk50`, 0 °C corner | +2.482 ns | 0.000 |
| Hold `clk50`, 0 °C corner | +0.227 ns | 0.000 |
| Setup, HPS SDRAM write clock | +2.563 ns | 0.000 |
| Hold, HPS SDRAM write clock | +0.143 ns | 0.000 |

All corners met with no failing paths. The setup slack of 2.401 ns on a
20 ns period means the critical path is 17.6 ns; the design would close at
roughly 57 MHz.

### Warnings

Two Critical Warnings, both expected:

| Warning | Meaning |
|---------|---------|
| 169085 — no exact pin location for 37 of 46 pins | The HPS DDR3 pins are placed by the hard IP, not by an assignment. A consequence of the placeholder SDRAM configuration; [05](05-fpga-design.md) §5.7. |
| 174073 — no exact pin location for the RZQ pin | Same. |

**Critical Warning 127003 (missing memory initialisation file) is gone.**
It was present in every previous build. Its absence is what makes the boot
contract in [07](07-shared-memory-protocol.md) §7.4 a property of the design
rather than an accident of a broken path.

Warning 171167 (invalid fitter assignments) is still present, but the
Ignored Assignments table went from 23 entries to 14 after nine assignments
naming non-existent DQS groups were removed. The six that remain cannot
apply to a hardened memory controller at all;
[BUILD-NOTES](BUILD-NOTES.md) §5 explains why and says they can be deleted.

Output: `output_files/HFTTop.sof`, 7,354,602 bytes.

## 13.3 Simulation

```bash
Testbenches/run_sim.sh
```

```
== Regenerating the memory map and the program ==
   PASS generated sources are current

== Python: ISA, assembler, simulator, strategy ==
   Ran 96 tests in 1.4s
   OK
   PASS python unit tests

== RTL: ALU equivalence against the golden model ==
   PASS tb_alu

== RTL: full chain, HPS protocol against the real top level ==
   PASS tb_fmma

== RTL: latency budget ==
   PASS tb_latency
     idle loop period            : 39 cycles = 780 ns
     quote -> signal (decision)  : 195 cycles = 3900 ns
     quote -> suppressed (risk)  : 169 cycles = 3380 ns

== Summary ==
   5 passed, 0 failed, 0 skipped
   all green
```

Total wall-clock: about 25 seconds.

### Detail: `tb_alu`

```
tb_alu: 9548 vectors checked, 0 failures
=== tb_alu PASSED ===
```

Every ALU opcode against a grid of sign-boundary and realistic values, every
shift amount 0–31, both carry-in states for `ADDC`/`SUBC`, and 256
deterministic pseudo-random cases per opcode. The 32-bit result and all five
flag bits are compared against `Software/fmma_sim.py`.

This is what licenses the Python layers: the golden model is not merely
*asserted* to match the hardware, it is *checked* to.

### Detail: `tb_fmma`

31 assertions, 0 failures, on the real `HFTTop` driven through the stub's
`s1` bridge port. Full list in [12](12-verification-plan.md) §12.3; the ones
worth naming here:

* the CPU parks at the entry word until the loader writes it — so a
  partially written program can never start
* the datapath probe passes and `FW_VERSION` is published
* a $20 fall gives BUY and a $20 rise gives SELL, each tagged with the quote
  that caused it
* the position limit blocks a buy at +MAX, counts it, sets the status bit,
  and still allows the sell that would reduce the position
* the master switch suppresses everything and reports itself
* a half-written quote is ignored; the same quote once completed is acted on
* `CFG_RESTART` re-initialises state; `KEY[0]` resets the CPU and it recovers
* **the two RAM ports never wrote the same word in the same cycle**

### Detail: `tb_latency`

All three measurements inside budget (60 and 280 cycles). These are the
numbers [14](14-latency-and-performance.md) quotes.

## 13.4 Host program

```bash
docker run --rm -v "$PWD:/work" -w /work/Software debian:bookworm-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq build-essential libssl-dev python3 && make'
```

```
cc -O2 -Wall -Wextra -Wno-unused-parameter -std=gnu11 \
   -DMG_TLS=MG_TLS_OPENSSL -DMG_ENABLE_PACKED_FS=0 \
   -o marketstream the host application mongoose.c -lssl -lcrypto -lrt -lm
-rwxr-xr-x 1 root root 179704 marketstream
```

**0 errors, 0 warnings.** Linked against OpenSSL 3.

`make check-generated` also passes **in the container**, which is the test
that matters: it regenerates the memory map and the program image on Linux
and diffs them against the files generated on Windows. It failed the first
time it was run there, because Python was translating line endings — the
generated files were CRLF on Windows and LF on Linux. Fixed by writing them
with an explicit `newline="\n"`, plus a `.gitattributes`. That is exactly
the class of bug the check exists for.

## 13.5 On the board

**Run, on a Terasic DE1-SoC, 11 September 2026.** Serial console on
`COM5`, Ethernet on `192.168.1.198/24`, FPGA configured from Linux with
no JTAG cable.

### 13.5.1 Bring-up

| Check | Result |
|-------|--------|
| `MSEL` reads `01010` (FPPx16) | **pass** — `SW10.4` OFF, `SW10.5` ON |
| `deploy.py fpga` reports `user mode`, no timeout | **pass** |
| `fmma-probe ramtest` | **pass** — 256 words, 32 data bits, 0 errors |
| `CPU running: protocol v2` | **pass** — program verified, 154 words |
| CPU idle loop rate | 1 282 151 loops/s, **0.78 µs per loop** |

The environment itself decided two build questions:

| Finding | Consequence |
|---------|-------------|
| Kernel 3.13, **gcc 4.6.3**, glibc 2.15 | the build uses `-std=gnu99`; gcc 4.6 has no C11 mode |
| `libssl.so` present, **headers absent**, Ubuntu 12.04 archives gone | `marketstream` cannot be built on the board at all — see 13.5.4 |
| `/dev/fpga0` and the three FPGA bridges present | the FPGA is configurable from Linux |
| Ethernet, DHCP and DNS to the exchange all work | the live feed is reachable |
| The 2012 CA bundle still validates Coinbase | no CA bundle needs shipping; `--ca` remains available if that changes |

`MSEL` was what blocked everything before this. In Active Serial mode
(`10010`, the factory setting) the FPGA loads itself from the on-board
EPCQ flash and the FPGA manager refuses every bitstream — including the
board's own `soc_system.rbf` — with `Invalid MSEL setting` followed by a
timeout. It looks exactly like a bad bitstream and is not; §11.4.

It also produced the project's one hardware incident: a configuration
that had silently failed left the fabric unconfigured, and the next read
of the bridge hung the board hard enough to need a power cycle. That is
now impossible by construction — every path that maps the bridge asks
the FPGA manager first — and it is written up in
[11](11-board-bringup.md) and [15](15-troubleshooting.md) §15.2.

### 13.5.2 Fabric latency, synthetic series

`fmma-bench` drives the protocol with a square wave one price unit
outside the band, so every quote produces a decision, and busy-polls for
the answer. 5 000 ticks, 300 µs apart:

| Measure | Result |
|---------|--------|
| Ticks published | 5 000 |
| Decisions read back | **5 000** — none missed, none late |
| Quote → decision, min / mean | **3 µs / 5 µs** |
| Quote → decision, p99 / max | **16 µs / 17 µs** |
| Same strategy on the ARM core | mean 999 ns, max 13.1 µs |
| Side disagreements, fabric vs software | **0 of 5 000** |

The last row is the equivalence result: the assembly running in the
fabric and the C transcription in [`fmma_strategy.c`](../Software/src/fmma_strategy.c)
reached the same decision on every one of five thousand quotes. Taken
with the 9 548 ALU vectors (§13.2) and the RTL assertions (§13.3), the
strategy is checked at three levels against the same golden model.

The fabric figure is a **full round trip** — seqlock publish, CPU loop,
decide, host poll — not the CPU's compute time. The ARM figure is
strategy arithmetic only, with no bridge in it. They are not competing
numbers; [14](14-latency-and-performance.md) says why at more length.

### 13.5.3 End to end, live market data

`marketstream` against the Coinbase `ticker` channel for BTC-USD, with
`--dry-run` so no order leaves the board (see 13.5.5), threshold $2.00:

```
[   0.852] info  feed  connected, subscribed to BTC-USD ticker
[   0.984] info  app   >>> FPGA SELL  (tick 10104, 5 us after the quote, fabric position 0)
[   8.482] info  app   >>> FPGA BUY   (tick 10192, 32 us after the quote, fabric position 0)
[  10.488] info  app   >>> FPGA SELL  (tick 10230, 6 us after the quote, fabric position 0)
```

| Window | Ticks | Decisions | min | mean | p99 | max |
|--------|-------|-----------|-----|------|-----|-----|
| 90 s, `--poll-ms 1` (default) | 424 | 23 | 5 µs | 157 µs | 1082 µs | 1082 µs |
| 40 s, `--poll-ms 0` (busy) | 184 | 9 | 5 µs | **12 µs** | 48 µs | 48 µs |

The millisecond tail in the first row is **the host, not the fabric**.
With a 1 ms poll interval a decision that lands just after a poll waits
most of a millisecond to be noticed, and 1082 µs is that interval plus
the work either side of it. Busy-polling removes it and the live figure
collapses onto the synthetic one. This is worth stating plainly because
it is the single largest term in the end-to-end number, it is entirely
on the software side, and quoting the 1082 µs as "FPGA latency" would be
wrong.

No feed drops, no parse errors, no missed signals in the busy-poll run.
The default-poll run recorded one `decision(s) arrived faster than this
loop could read them` during a burst — the sequence-counter edge
detection caught it and said so, which is the behaviour §7 specifies.

### 13.5.4 Cross-building, and why it is necessary

The board has `libssl.so` but not `openssl/ssl.h`, and Ubuntu 12.04's
archives are gone, so `apt-get install libssl-dev` cannot succeed. The
two diagnostics build on the board in about a second; `marketstream`
cannot be built there at all.

[`tools/Dockerfile.armhf`](../tools/Dockerfile.armhf) and
[`tools/crossbuild.sh`](../tools/crossbuild.sh) produce a **static**
armhf binary from a current Debian. Static because the toolchain has
glibc 2.36 and the board has 2.15, so a dynamically linked binary would
not start. Static glibc would normally break name resolution —
`getaddrinfo` loads NSS plugins at run time — but mongoose resolves
names itself over UDP and never calls it.

```
marketstream: ELF 32-bit LSB executable, ARM, EABI5, statically linked,
              for GNU/Linux 3.2.0
```

`deploy.py pushbin` copies the result over HTTP.

### 13.5.5 What was not run, and why

| Not run | Reason |
|---------|--------|
| A live Alpaca paper order | The API key committed in `d65ee28` is exposed in git history and **must be revoked before any key is used on this board**. Every run here used `--dry-run`, which logs the order and sends nothing. See [18](18-security-and-compliance.md). |
| Visual confirmation of `HEX0` | Requires someone at the bench. `fmma-probe ramtest` and the CPU's own version word establish the same thing electrically. |
| `market_maker.asm` on hardware | Verified in simulation and against the ISS (§13.2, §13.4); `trading.asm` is the default image and is what was measured here. |

Once the key is revoked and a fresh one exported, the remaining step is
one command — `sudo -E ./marketstream --threshold 200` without
`--dry-run` — and the check is that Alpaca's dashboard shows the fill
and the fabric's `POSITION` word agrees with it.

## 13.6 Requirement coverage

Every functional requirement (FR-1…FR-15) and non-functional requirement
(NFR-1…NFR-10) in [01-requirements](01-requirements.md) names its verifying
test in the right-hand column, and all of those tests are in the passing
sets above.

The two requirements that can only be *fully* closed on hardware are FR-1
(a live feed) and FR-6 (a real order). Both are exercised off-board —
FR-1 by `--no-fpga` against the live Coinbase endpoint, FR-6 by `--dry-run`
— but the end-to-end path is §13.5.

## 13.7 Reproducing this report

```bash
Testbenches/run_sim.sh                             # §13.3
quartus_sh --flow compile HFTTop                   # §13.2, ~48 min
cat output_files/HFTTop.fit.summary
cat output_files/HFTTop.sta.summary
docker run --rm -v "$PWD:/work" -w /work/Software debian:bookworm-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq build-essential libssl-dev python3 \
   && make && make check-generated'                # §13.4
```
