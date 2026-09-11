# Archived testbenches (ECE 3710, 2025)

These are the testbenches the original CPU was developed against in ECE 3710.
They are kept for provenance, not because they run: the design has moved on
and most of them no longer compile against `Code/`.

| File | State | Why |
|------|-------|-----|
| `tb_FSM.v` | dead | instantiates `FSM`, a lab-2 module that is not in this repository |
| `tb_FSMMem.v` | dead | instantiates `FSMMem`, likewise |
| `tb_FibTop.v` | dead | instantiates `FibTop`, the Fibonacci demo top level |
| `tb_MemTop.v` | dead | instantiates `MemTop` |
| `tb_MUX16to1.v` | stale | written for 16-bit muxes; the datapath is 32-bit now |
| `tb_MUX2to1.v` | stale | same |
| `tb_bram.v` | obsolete | tests `Code/bram.v`, which the Qsys on-chip RAM replaced |
| `tb_HFTTop.v` | superseded | the protocol v1 full-chain test; `../tb_fmma.v` replaces it |
| `tb_debug.v` | superseded | ad-hoc probe used while bringing the CPU up |
| `tb_final`, `tb`, `tb_Final * Results` | data | captured ModelSim output from the 2025 lab reports |

What replaced them:

* `../tb_alu.v` checks `Code/ALUFinal` against the golden model for ~9,500
  generated vectors, which covers every opcode and every flag rather than the
  handful `tb_ALU.v` used to.
* `../tb_fmma.v` drives the real top level through the whole protocol, so the
  muxes, register bank, PC, IR and flag register are exercised continuously by
  a program that has to produce the right answers.
* `../../Software/test_toolchain.py` and `test_strategy.py` cover the ISA and
  the strategy decision table in the instruction set simulator.

See `../../docs/12-verification-plan.md` for how the pieces fit together and
what each one is responsible for proving.
