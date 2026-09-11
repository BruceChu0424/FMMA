# FMMA documentation

FPGA Market Maker Accelerator — ECE 4900 senior design, Utah State University.
A custom 32-bit RISC CPU in a Cyclone V FPGA makes trading decisions on live
market data; the ARM host on the same chip does the networking and the order
execution.

Start with the [top-level README](../README.md) if you just want to build and
run it. These documents are the engineering record.

## Reading order

If you are new to the project, read 02, then 07, then 08.

| # | Document | What it answers |
|---|----------|-----------------|
| 01 | [Requirements](01-requirements.md) | What the system must do, with IDs and a traceability matrix |
| 02 | [System architecture](02-system-architecture.md) | How the pieces fit together and why the split is where it is |
| 03 | [CPU microarchitecture](03-cpu-microarchitecture.md) | The datapath and control FSM, cycle by cycle |
| 04 | [ISA reference](04-isa-reference.md) | Every instruction, encoding, flag and condition code |
| 05 | [FPGA design](05-fpga-design.md) | Top level, Qsys system, clocking, reset, pins, resources |
| 06 | [HPS software design](06-hps-software-design.md) | The Linux program: feed, loader, execution, instrumentation |
| 07 | [Shared memory protocol](07-shared-memory-protocol.md) | **The HPS ↔ FPGA contract.** The most important document here |
| 08 | [Trading strategy](08-trading-strategy.md) | What the CPU actually decides, and why |
| 09 | [Risk management](09-risk-management.md) | Position limits, kill switches, what is and is not protected |
| 10 | [Build guide](10-build-guide.md) | Toolchains, commands, and the traps on this machine |
| 11 | [Board bring-up runbook](11-board-bringup.md) | From a bare DE1-SoC to a running demo |
| 12 | [Verification plan](12-verification-plan.md) | What is tested, by what, and what is deliberately not |
| 13 | [Test report](13-test-report.md) | Results, with the commands that produced them |
| 14 | [Latency and performance](14-latency-and-performance.md) | Measured numbers and where the time goes |
| 15 | [Troubleshooting](15-troubleshooting.md) | Symptom → cause → fix |
| 16 | [Project plan](16-project-plan.md) | Scope, schedule, responsibilities, status |
| 17 | [Glossary](17-glossary.md) | Terms from both halves of this project |
| 18 | [Security and compliance](18-security-and-compliance.md) | Credentials, paper trading only, the key incident |

Tooling worth knowing about:

| Tool | What it is for |
|------|----------------|
| [`../Testbenches/run_sim.sh`](../Testbenches/run_sim.sh) | the whole off-board regression suite, 25 seconds |
| [`../tools/boardctl.py`](../tools/boardctl.py) | a scriptable serial console for the board |
| [`../tools/deploy.py`](../tools/deploy.py) | one command per bring-up step: network, FPGA, push, build, probe, run |
| `Software/src/fmma_probe.c` | `fmma-probe`, the on-board HPS/FPGA link diagnostic |
| [`../Software/protocol.py`](../Software/protocol.py) | the memory map; generates the C, assembly and Verilog copies |
| [`../Software/fmma_sim.py`](../Software/fmma_sim.py) | the golden-reference instruction set simulator |

Also in the repository:

* [`../CHANGELOG.md`](../CHANGELOG.md) — what changed and when
* [`../CONTRIBUTING.md`](../CONTRIBUTING.md) — how to work on this
* [`../THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md) — licences of vendored code
* [`BUILD-NOTES.md`](BUILD-NOTES.md) — machine-specific toolchain fixes (appendix to 10)
* [`3710ProjectReview.pdf`](3710ProjectReview.pdf) — the ECE 3710 final report the CPU came from
* [`Project Topic.pdf`](Project%20Topic.pdf) — the original project proposal

## Conventions used throughout

* **Word** means a 32-bit word of the shared on-chip RAM. Addresses in the
  protocol are word indices, not byte offsets; byte offset = 4 × word index.
* **Price units** are cents: an integer scaled by `FMMA_PRICE_SCALE` = 100.
* **Lot** is the unit of inventory, one `--qty` order (0.001 BTC by default).
* Cycle counts are 50 MHz clocks, 20 ns each.
* Anything stated as a measurement was measured; the command that produced it
  is given next to it. If a number here disagrees with the tool output, the
  tool is right and this is a bug.
