# 16. Project plan and status

**Course:** ECE 4900 senior design, Utah State University
**Group:** 20
**Team:** Carlos Zavala, Kaleb Neilson, Zhenwei (Bruce) Zhu
**Advisor:** Jon Davies
**Origin:** the CPU is the ECE 3710 group 1011 design (Henry Wilson, Bobby
Lofgren, Kaleb Neilson, Carson Ord)

## 16.1 Objective

Demonstrate a complete, working split between a networking host and an
FPGA-resident decision engine for a market-making application: live market
data in, a hardware trading decision, a real (paper) order out, with the
latency measured and the risk bounded in hardware.

## 16.2 Status of the original work breakdown

The fourteen items the team defined at the start, and where each one stands.

| # | Item | Status | Where |
|---|------|--------|-------|
| 1 | AXI bridge and memory map research | done | [07](07-shared-memory-protocol.md) |
| 2 | On-chip RAM instantiation | done | `HPSfgpa2.qsys`, [05](05-fpga-design.md) §5.2 |
| 3 | AXI bridge configuration | done | lightweight H2F at 0xFF200000, base 0x0000 |
| 4 | HPS userspace memory-mapped I/O | done | `map_bridge` in `MarketStream.c` |
| 5 | **Data consistency and synchronisation protocol** | done | seqlock + publish-last + `OLD_DATA`; [07](07-shared-memory-protocol.md) §7.5–7.8 |
| 6 | WebSocket client on the HPS | done | `ticker` channel, TLS via OpenSSL, reconnect with backoff |
| 7 | JSON parsing and field extraction | done | `parse_scaled`, `json_str_field`, exact integer parsing |
| 8 | Write parsed fields to shared RAM | done | `publish_tick` |
| 9 | **End-to-end latency measurement (software)** | done | `SIGNAL_TICK` attribution + the tick-time ring; [14](14-latency-and-performance.md) |
| 10 | FPGA simulation and hardware validation | simulation done; **board validation outstanding** | [12](12-verification-plan.md), [11](11-board-bringup.md) |
| 11 | **Risk limits and inventory** | done | `POSITION`, `CFG_MAX_POS`, `REJECTS`; [09](09-risk-management.md) |
| 12 | FPGA ↔ HPS signalling | done | `SIGNAL_SEQ` edge detection |
| 13 | HPS receives FPGA trade signals | done | `poll_fpga` → Alpaca |
| 14 | **Latency profiling, HPS versus FPGA** | done | `--bench`; [14](14-latency-and-performance.md) §14.5 |

Items 5, 9, 11 and 14 were the four that had no implementation at all before
this revision; they are the substance of what changed.

**Inventory skew** — part of item 11 as originally worded — is not
implemented, because it only means something for a two-sided quoting
strategy. The memory map reserves `CFG_SKEW` and `QUOTE_BID`/`QUOTE_ASK` for
it; see [08](08-trading-strategy.md) §8.6.

## 16.3 Timeline

| Phase | Period | Outcome |
|-------|--------|---------|
| ECE 3710 | Autumn 2025 | The 32-bit CPU: ALU, control FSM, register bank, assembler, Fibonacci demo. HPS integration attempted, not completed. |
| Spring 2026 | Jan–Apr | Project defined, advisor secured, milestone presentation. HPS↔FPGA link brought up: writes from Linux visible on the seven-segment display. |
| Summer 2026 | May–Aug | Paused. |
| Autumn 2026 | Sep | **This revision.** Protocol v2, risk layer, latency instrumentation, datapath and ALU fixes, verification suite, documentation. |
| Remaining | — | On-board validation of the full chain (§16.5). |

## 16.4 What changed in this revision

Fully in [`../CHANGELOG.md`](../CHANGELOG.md); the parts that matter for
grading:

**Defects found and fixed.** The ALU's shift instructions were wrong for
every right shift; `SUB` and `SUBC` never set the flags a conditional branch
needs; `CMP`'s unsigned flag was wrong for mixed signs; the carry input was
tied to zero, so `ADDC` was `ADD`; and — the serious one — **every I-type
instruction had its operands reversed**, so `SUB Rd,#k` computed `k − Rd` and
`MOV Rd,#k` did nothing. Eight of fifteen branch mnemonics the assembler
emitted were not decoded by the hardware at all and were silently never
taken; one more was decoded but was unconditionally true.

**Design gaps closed.** There was no consistency mechanism between the two
processors, no risk layer, no way to restart the CPU without reconfiguring
the FPGA, no latency instrumentation, and the host build produced a binary
with TLS compiled out.

**Verification built.** From zero automated tests to 82 Python tests, ~9,500
ALU equivalence vectors against the RTL, a 31-assertion full-chain testbench
and a timing-budget testbench, all behind one script.

## 16.5 Remaining work

### Required to finish the project

| Task | Owner | Notes |
|------|-------|-------|
| On-board validation of the full chain | team | [11](11-board-bringup.md) is the procedure; §11.8 lists the checks. This is the only thing simulation cannot substitute for. |
| Record the `--bench` output | team | Fills in [13](13-test-report.md) §13.5. |
| Rotate the leaked Alpaca key | key owner | [18](18-security-and-compliance.md) §18.4. **Do this first.** |

### Worth doing, in rough priority order

| Task | Why |
|------|-----|
| Correct the HPS SDRAM parameters in the Qsys system | The committed handoff describes the wrong memory and must never be used to build a preloader. Needs a full Quartus Standard install. [05](05-fpga-design.md) §5.7. |
| A fixed-function decision datapath | The honest answer to "why an FPGA". ~70× faster than the CPU running the same algorithm. [14](14-latency-and-performance.md) §14.7. |
| Two-sided quoting with inventory skew | What would make this a market maker rather than a trigger. [08](08-trading-strategy.md) §8.6. |
| Order-status polling | Turns "accepted" into a real fill report and closes the largest risk gap. [09](09-risk-management.md) §9.6. |
| A doorbell instead of polling | Removes up to 780 ns of staleness. |
| P&L tracking and a loss limit | The one risk control that is entirely absent. |
| Gate-level simulation | Needs a Questa licence. |

## 16.6 Responsibilities

| Area | Lead |
|------|------|
| CPU RTL and the ECE 3710 design | Kaleb Neilson |
| HPS/Linux integration, board bring-up | Kaleb Neilson, Carlos Zavala |
| Project planning, presentations, coursework deliverables | Carlos Zavala |
| Protocol, strategy, toolchain, verification, documentation | Zhenwei Zhu |

## 16.7 Risks to completion

| Risk | Impact | Mitigation |
|------|--------|------------|
| Network access for the board | Blocks the live demo entirely | A campus network needs a MAC exception; a home router or a hotspot works today. Plan for this before demo day. |
| Board availability | Blocks §16.5 | The design is fully simulated, so board time is needed for validation, not development. |
| The Quartus Lite IP gap | Blocks a clean Qsys regeneration | Documented and worked around; only matters if the HPS configuration has to change. |
| Alpaca API changes | Breaks execution | Paper endpoint, stable API; `--dry-run` keeps the rest of the chain demonstrable regardless. |

## 16.8 Deliverables

| Deliverable | State |
|-------------|-------|
| Working FPGA bitstream | `output_files/HFTTop.sof`, timing closed |
| CPU program and toolchain | `trading.asm`, assembler, simulator, all tested |
| Host application | `MarketStream.c`, builds clean with `-Wall -Wextra` |
| Verification suite | `Testbenches/run_sim.sh`, green |
| Documentation | this `docs/` tree |
| Demonstration | pending §16.5 |
