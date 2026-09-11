# 1. Requirements and specification

## 1.1 Problem statement

High-frequency trading systems are limited by how fast a price change can be
turned into an order. A general-purpose CPU running an operating system adds
microseconds of scheduling, cache and syscall jitter to a decision that is
arithmetically trivial. The premise of this project is that moving the
decision into FPGA fabric makes it both faster and *deterministic* — the same
input always takes the same number of clock cycles.

FMMA is a complete, working demonstration of that split on hardware a senior
design team can actually get: a Terasic DE1-SoC, which puts a Cyclone V FPGA
and a dual-core ARM Cortex-A9 on one die with a bus between them.

## 1.2 Scope

**In scope.** A live market-data feed, a decision engine in fabric, order
execution against a paper-trading broker, a risk layer, and the measurement
infrastructure to show what the fabric buys.

**Out of scope, deliberately.** Real money (see
[18-security-and-compliance](18-security-and-compliance.md)); a full limit
order book; an exchange-native protocol such as ITCH or OUCH; sub-microsecond
network I/O. The last two are out of reach because the only market data
available from a university lab is a public WebSocket feed over the internet,
which costs tens of milliseconds — three orders of magnitude more than the
decision itself. Section [14](14-latency-and-performance.md) is explicit about
this: the project optimises and measures the part it can control, and says so.

## 1.3 Functional requirements

| ID | Requirement | Verified by |
|----|-------------|-------------|
| FR-1 | The system shall receive live best-bid/best-ask quotes for a configurable product from a public market data feed. | [13](13-test-report.md) §HPS, manual on-board run |
| FR-2 | Quotes shall be delivered to the FPGA as fixed-point integers with no loss of the exchange's quoted precision. | `test_toolchain`, the host application `parse_scaled` |
| FR-3 | The trading decision shall be computed in FPGA fabric, not on the host CPU. | `tb_fmma` steps 3–6 |
| FR-4 | The decision engine shall emit a buy signal, a sell signal, or nothing, for each quote it consumes. | `test_strategy.TestDecisions` |
| FR-5 | Each signal shall identify the quote that produced it, so latency can be attributed. | `tb_fmma` step 5, `test_strategy.test_signal_carries_the_tick_that_caused_it` |
| FR-6 | The host shall execute signals as orders against a paper-trading broker. | the host application `send_order`, on-board run |
| FR-7 | The host shall report fills back to the FPGA so that its inventory matches the broker's. | `tb_fmma` step 8, `test_strategy.TestFillAccounting` |
| FR-8 | The decision engine shall refuse to increase a position beyond a configurable limit. | `tb_fmma` step 9, `test_strategy.TestRiskLimits` |
| FR-9 | The system shall provide a single switch that suppresses all trading while leaving the engine running and observable. | `tb_fmma` step 11 |
| FR-10 | Strategy parameters (threshold, position limit, starting inventory) shall be configurable at run time without rebuilding the bitstream. | `test_strategy` (every test sets them), `--threshold`/`--max-pos` |
| FR-11 | The host shall be able to load a new decision program and restart the engine without reconfiguring the FPGA. | `tb_fmma` step 13, `test_strategy.TestSoftwareRestart` |
| FR-12 | The engine shall be resettable from the board. | `tb_fmma` step 14 |
| FR-13 | The engine shall publish a liveness indicator the host can check. | `tb_fmma` step 2, `HEARTBEAT` |
| FR-14 | The system shall measure and report the latency from quote publication to decision. | `tb_latency`, the host application statistics block |
| FR-15 | The system shall be able to run the same strategy in host software, for comparison. | `the host application --no-fpga --bench` |

## 1.4 Non-functional requirements

| ID | Requirement | Target | Measured | Verified by |
|----|-------------|--------|----------|-------------|
| NFR-1 | Decision latency, quote visible in shared memory → signal visible | ≤ 5 µs | 3.90 µs | [`tb_latency`](../Testbenches/tb_latency.v) |
| NFR-2 | Decision latency shall be deterministic (no variance from load, caches or scheduling) | exact | exact, by construction — the engine has no cache, no interrupts and one instruction timing | [03](03-cpu-microarchitecture.md) |
| NFR-3 | Engine poll period (how stale a quote can be before it is noticed) | ≤ 1.2 µs | 0.78 µs | `tb_latency` |
| NFR-4 | Timing closure at 50 MHz | positive slack | see [13](13-test-report.md) | `quartus_sta` |
| NFR-5 | Fabric utilisation | < 25 % of the device | see [13](13-test-report.md) | `quartus_fit` |
| NFR-6 | The host and the engine shall never observe a partially written data structure | never | never, by seqlock | [07](07-shared-memory-protocol.md), `tb_fmma` step 12 |
| NFR-7 | No decision shall be lost or executed twice because of a race between the two sides | never | never, by publish-last sequencing | [07](07-shared-memory-protocol.md) |
| NFR-8 | Credentials shall never appear in the source tree or in build output | never | enforced by review; see [18](18-security-and-compliance.md) | `.gitignore`, `getenv` only |
| NFR-9 | A program built for one ISA revision shall not run silently on a bitstream built for another | must fail loudly | fails loudly | datapath probe, `tb_fmma` step 2 |
| NFR-10 | The full off-board test suite shall run in under two minutes on a laptop | ≤ 120 s | ~25 s | `Testbenches/run_sim.sh` |

## 1.5 Interface requirements

| ID | Interface | Specification |
|----|-----------|---------------|
| IR-1 | HPS ↔ FPGA | 4 KB dual-port on-chip RAM on the lightweight AXI bridge at `0xFF200000`. Contract in [07](07-shared-memory-protocol.md). |
| IR-2 | Market data | Coinbase Exchange WebSocket, `ticker` channel, TLS. |
| IR-3 | Order entry | Alpaca paper trading REST API, `POST /v2/orders`, TLS, credentials from the environment. |
| IR-4 | Operator | Serial console at 115200 baud; `KEY[0]` resets the engine; `HEX0` shows the low nibble of the program counter. |

## 1.6 Constraints

| ID | Constraint | Consequence |
|----|------------|-------------|
| C-1 | The decision engine is the ECE 3710 CPU, reused rather than redesigned. | 16 registers, no stack, no indexed addressing, three cycles per instruction. The strategy is written around that; see [08](08-trading-strategy.md). |
| C-2 | Quartus Prime 25.1 **Lite** is the only licence available. | No EMIF/UniPHY IP generation, so the Qsys system cannot be fully regenerated on the development machine. See [05](05-fpga-design.md) §5.7 and [10](10-build-guide.md). |
| C-3 | No Questa licence. | Simulation uses Icarus Verilog. |
| C-4 | Market data must come over the public internet. | Feed latency dominates end-to-end latency by ~10⁴×. Acknowledged and quantified in [14](14-latency-and-performance.md). |
| C-5 | Paper trading only. | No real capital is at risk; the risk layer is still implemented and tested, because the point is to demonstrate it. |

## 1.7 Requirement status

Every functional and non-functional requirement above is implemented and
verified off-board. The one thing no simulation can establish is that the
whole chain works on the physical board with a live feed; that is the
remaining item, and [11](11-board-bringup.md) is the procedure for it.
[16](16-project-plan.md) tracks it.
