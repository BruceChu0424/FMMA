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
| 4 | HPS userspace memory-mapped I/O | done | `fmma_fpga_open` in `src/fmma_fpga.c` |
| 5 | **Data consistency and synchronisation protocol** | done | seqlock + publish-last + `OLD_DATA`; [07](07-shared-memory-protocol.md) §7.5–7.8 |
| 6 | WebSocket client on the HPS | done | `ticker` channel, TLS via OpenSSL, reconnect with backoff |
| 7 | JSON parsing and field extraction | done | `parse_scaled`, `json_str_field`, exact integer parsing |
| 8 | Write parsed fields to shared RAM | done | `publish_tick` |
| 9 | **End-to-end latency measurement (software)** | done, **measured on hardware** | `SIGNAL_TICK` attribution + the tick-time ring; 5 µs mean over 5,000 quotes; [14](14-latency-and-performance.md) |
| 10 | FPGA simulation and hardware validation | **done, both** | 6 simulation stages + 31 hardware checks; [13](13-test-report.md) §13.5 |
| 11 | **Risk limits and inventory** | done | `POSITION`, `CFG_MAX_POS`, `REJECTS`; [09](09-risk-management.md) |
| 12 | FPGA ↔ HPS signalling | done | `SIGNAL_SEQ` edge detection |
| 13 | HPS receives FPGA trade signals | done | `poll_fpga` → Alpaca |
| 14 | **Latency profiling, HPS versus FPGA** | done, **measured on hardware** | `fmma-bench` and `--bench`; both figures in [14](14-latency-and-performance.md) §14.5 |

All fourteen items are implemented and, as of 11 September 2026, all
fourteen have been exercised on the board. The one thing still not
done is a *live paper order*, which is blocked on rotating the leaked
key rather than on any engineering — see §16.5.

Items 5, 9, 11 and 14 were the four that had no implementation at all before
this revision; they are the substance of what changed.

**Inventory skew** — part of item 11 as originally worded — is now
implemented, in `market_maker.asm`: the quoting strategy leans both
quotes against the position by `CFG_SKEW` per lot and publishes them in
`QUOTE_BID`/`QUOTE_ASK`. [08](08-trading-strategy.md) §8.6.

## 16.3 Timeline

| Phase | Period | Outcome |
|-------|--------|---------|
| ECE 3710 | Autumn 2025 | The 32-bit CPU: ALU, control FSM, register bank, assembler, Fibonacci demo. HPS integration attempted, not completed. |
| Spring 2026 | Jan–Apr | Project defined, advisor secured, milestone presentation. HPS↔FPGA link brought up: writes from Linux visible on the seven-segment display. |
| Summer 2026 | May–Aug | Paused. |
| Autumn 2026 | Sep | **This revision.** Protocol v2, risk layer, latency instrumentation, datapath and ALU fixes, a modular host application, the quoting strategy, board tooling, verification suite, documentation. |
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

**Verification built.** From zero automated tests to 99 Python tests, 63 C unit
checks, 9,548 ALU equivalence vectors against the RTL, a 31-assertion
full-chain testbench, an ISA conformance testbench and a timing-budget
testbench, all behind one script — plus two suites that run the same
properties against the real fabric (21 protocol checks, 10 ISA checks).

**It runs.** The CPU is in the fabric on a real DE1-SoC, answering live
Coinbase quotes in about 5 µs, with the software model agreeing on all
5,000 quotes of a synthetic sweep. [13](13-test-report.md) §13.5.

## 16.5 Remaining work

### Required to finish the project

| Task | Owner | Notes |
|------|-------|-------|
| **Rotate the leaked Alpaca key** | key owner | [18](18-security-and-compliance.md) §18.4. **The only thing blocking the last step.** |
| One live paper order, end to end | team | Everything else is done and measured. Drop `--dry-run` once the key is rotated; check the fill against Alpaca's dashboard and the fabric's `POSITION`. |
| ~~On-board validation of the full chain~~ | — | **Done** — [13](13-test-report.md) §13.5. |
| ~~Record the latency figures~~ | — | **Done** — §13.5.2 and §13.5.3. |

### Worth doing, in rough priority order

| Task | Why |
|------|-----|
| Correct the HPS SDRAM parameters in the Qsys system | The committed handoff describes the wrong memory and must never be used to build a preloader. Needs a full Quartus Standard install. [05](05-fpga-design.md) §5.7. |
| A fixed-function decision datapath | The honest answer to "why an FPGA". ~70× faster than the CPU running the same algorithm. [14](14-latency-and-performance.md) §14.7. |
| Resting limit orders with cancel/replace | `market_maker.asm` simulates quoting with market orders; real quoting needs a broker API that can cancel and replace quickly. [08](08-trading-strategy.md) §8.6. |
| A doorbell instead of polling | Removes up to 780 ns of staleness. |
| Fractional inventory | The protocol counts whole lots, so a partial fill is rounded. [09](09-risk-management.md) §9.6. |
| Query the broker's position at startup | Closes the "host died mid-order" gap; the `--position` hook already exists. |
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
| CPU program and toolchain | `trading.asm` and `market_maker.asm`, assembler, simulator, all tested |
| Host application | thirteen modules under `Software/src/`, builds clean with `-Wall -Wextra` |
| Verification suite | `Testbenches/run_sim.sh`, green |
| Documentation | this `docs/` tree |
| Demonstration | pending §16.5 |
