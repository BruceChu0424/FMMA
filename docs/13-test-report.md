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
| Python: ISA, assembler, simulator | **82 / 82 pass** |
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
— 48 minutes 29 seconds, 47 of them in the fitter.

### Resource usage

From `output_files/HFTTop.fit.summary`:

| Resource | Used | Available | % |
|----------|-----:|----------:|--:|
| Logic (ALMs) | 1,200 | 32,070 | 4 % |
| Registers | 1,130 | — | — |
| Pins | 46 | 457 | 10 % |
| Block memory | 32,768 bits | 4,065,280 | < 1 % |
| M10K blocks | 4 | 397 | 1 % |
| DSP blocks | 2 | 87 | 2 % |
| PLLs | 0 | 6 | 0 % |
| DLLs | 1 | 4 | 25 % |

Almost all of this is the HPS hard IP and its DDR3 interface; the CPU
itself is a small part of it. The four M10K blocks are the 4 KB shared RAM
and the two DSPs are the ALU's multiplier.

Logic usage **fell** from 1,652 ALMs (5 %) in the previous build to 1,200
(4 %). The saving comes from the shift instructions: the old `LSH`/`ASH`
were written as unrolled loops that synthesised into two cascaded shifters,
and replacing them with a single signed-amount barrel shifter removed the
second one — while also making them produce the right answer
([CHANGELOG](../CHANGELOG.md)).

### Timing

From `output_files/HFTTop.sta.summary`, slow 1100 mV 85 °C corner:

| Check | Slack | TNS |
|-------|------:|----:|
| Setup `clk50` | **+2.505 ns** | 0.000 |
| Hold `clk50` | **+0.245 ns** | 0.000 |
| Recovery `clk50` | +16.195 ns | 0.000 |
| Removal `clk50` | +0.867 ns | 0.000 |
| Minimum pulse width `clk50` | +8.898 ns | 0.000 |
| Setup, HPS SDRAM write clock | +2.563 ns | 0.000 |
| Hold, HPS SDRAM write clock | +0.143 ns | 0.000 |

All corners met with no failing paths. The setup slack of 2.505 ns on a
20 ns period means the critical path is 17.5 ns; the design would close at
roughly 57 MHz.

The slow 1100 mV **0 °C** corner is also met (+2.543 setup, +0.232 hold).

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
   Ran 82 tests in 0.877s
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
   -o marketstream MarketStream.c mongoose.c -lssl -lcrypto -lrt -lm
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

**Not yet run.** This is the only outstanding item in the project
([16](16-project-plan.md) §16.5). [11-board-bringup](11-board-bringup.md) is
the procedure; §11.8 lists the six output lines that constitute the checks,
and §11.12 is the per-session checklist.

Record here, when it is done:

| Check | Result |
|-------|--------|
| `HEX0` steady `8` after configuration | |
| `[LOADER] Program verified.` | |
| `[LOADER] CPU running: protocol v2` | |
| `[FEED] connected` | |
| `>>> [FPGA] BUY/SELL` with a latency figure | |
| Alpaca accepts the order, position agrees with the dashboard | |
| `--bench` output (software vs fabric) | |
| Sustained run without an error or a lost signal | |

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
