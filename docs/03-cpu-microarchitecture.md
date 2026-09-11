# 3. CPU microarchitecture

The decision engine is the 32-bit RISC CPU designed by ECE 3710 group 1011
(Henry Wilson, Bobby Lofgren, Kaleb Neilson, Carson Ord), with the datapath
and control fixes described in [`../CHANGELOG.md`](../CHANGELOG.md). This
document describes what it is, not what it should have been; where a design
choice is awkward, the awkwardness is named.

## 3.1 Overview

| Property | Value |
|----------|-------|
| Data width | 32 bits |
| Registers | 16 × 32-bit, all general purpose, no hardware zero register |
| Address space | 1024 words, word-addressed (the shared on-chip RAM) |
| Memory ports used by the CPU | one — fetch, load and store are time-multiplexed |
| Instruction timing | exactly 3 clock cycles, every instruction, no exceptions |
| Pipelining | none |
| Interrupts | none |
| Clock | 50 MHz; CPU state changes on the **falling** edge |
| Reset | power-on counter, plus `KEY[0]` on the board |

Everything about this is unremarkable except the timing, which is the point:
there is no cache, no branch predictor, no memory hierarchy and no operating
system, so the same instruction sequence takes the same number of nanoseconds
every time it runs. That is what an FPGA buys here.

## 3.2 Block diagram

```
                  ┌────────────────────────────────────────────┐
                  │            shared on-chip RAM              │
                  │  port s2: one address, one data, one write │
                  └───▲──────────────┬─────────────────────────┘
       mem_addr       │              │ mem_rdata
  (LS|we) ? rAddr     │              ├──────────────┬───────────────┐
           : pc_out   │              │              │               │
                      │          ┌───▼────┐    ┌────▼─────┐         │
   ┌──────┐           │          │   IR   │    │  load    │         │
   │  PC  ├───────────┘          │ 32-bit │    │  data    │         │
   └──▲───┘                      └───┬────┘    └────┬─────┘         │
      │ PCnew                        │ instrR       │               │
   ┌──┴────┐                         │              │          ┌────▼─────┐
   │ Disp  │◄── control ─────┐       │              │          │ FSMtrial │
   │ +1    │                 │       │              │          │ (control)│
   │ +disp │◄── instrR[7:0]  │       │              │          └────┬─────┘
   │ =addr │◄── rAddr        │       │              │               │
   └───────┘                 │       │              │    op, rSrc, RI, Imm,
                             │       │              │    Ren, PCen, Fen,
   ┌─────────────────────────┴───┐   │              │    IRen, LS, we
   │      register bank          │   │              │
   │   R0 .. R15, 32-bit each    │   │              │
   └──┬───────────┬──────────────┘   │              │
      │ rDest     │ rSrc2            │              │
      │ (instrR   │ (rSrc from       │              │
      │  [11:8])  │  the FSM)        │              │
      │           │                  │              │
      │        ┌──▼──────┐           │              │
      │        │ immMUX  │◄── Imm ───┘              │
      │        │ RI ? Imm│                          │
      │        │  : rSrc2│                          │
      │        └──┬──────┘                          │
   ┌──▼───────────▼──┐                              │
   │    ALUFinal     │                              │
   │  C = A op B     │                              │
   └──┬──────────┬───┘                              │
      │ ALUout   │ flags                            │
      │      ┌───▼───┐                              │
      │      │  FR   │── flagsR ──► branch decode ──┘
      │      └───────┘
   ┌──▼───────────────┐
   │     ALUMUX       │◄── load data
   │  LS ? data : ALU │
   └──────┬───────────┘
          └────► register bank write port
```

## 3.3 Instruction timing

The control FSM and every CPU register clock on the **falling** edge of
`CLOCK_50`; the on-chip RAM clocks on the **rising** edge. That gives each
direction half a clock period (10 ns) to settle, and it is why one clock can
serve both without a wait state.

Every instruction is three states:

| State | Name | What happens |
|-------|------|--------------|
| S0 | fetch | `mem_addr = pc_out`. The RAM captures the address on the rising edge in the middle of this state; the instruction is on `mem_rdata` by the falling edge, and the IR latches it. |
| S1 | decode | The FSM decodes `mem_rdata` directly (not the IR) and sets up the control signals for the execute state. `PCen` and the next-PC selector are asserted here so they take effect in S2. |
| S2–S6 | execute | One of five: R/I-type, store, load, branch, jump. Each writes back, updates the PC, and returns to S0. |

Plus one state outside that cycle:

| State | Name | What happens |
|-------|------|--------------|
| hlt | halt / wait | Entered when the fetched word is `32'h00000000`. Polls the word at the PC once per clock and leaves as soon as it becomes non-zero. |

**3 cycles per instruction, 1 cycle per halt poll.** Measured over 100
iterations of the real strategy loop on the RTL: exactly 39 cycles for 13
instructions ([`tb_latency`](../Testbenches/tb_latency.v)).

### Why the decoder reads `mem_rdata` and the execute stage reads the IR

In S1 the RAM is still addressed by the PC, so `mem_rdata` *is* the
instruction and the FSM can decode it combinationally. By S3/S4 the address
has switched to `rAddr` for the load or store, so `mem_rdata` is data, not the
instruction — which is why the register and address multiplexers are driven
from `instrR` (the IR output) and not from `mem_rdata`. Getting this wrong is
the classic failure mode of a single-port design, and the original dual-port
version did not have to care.

## 3.4 The halt state is the boot mechanism

The on-chip RAM powers up zeroed, and a zero word is not a NOP — it is the
halt instruction. So after FPGA configuration the CPU sits at the entry word,
polling it once per clock, drawing a steady `8` on `HEX0`.

The host loader exploits this: it writes the whole program image *except* the
entry word, then writes the entry word last. Until that final write lands the
CPU sees zero and stays parked, so it is impossible for it to start executing
a half-written program. No reset handshake between the two sides is needed.

This is `load_program` in
[`../Testbenches/tb_fmma.v`](../Testbenches/tb_fmma.v) and
`load_fpga_program` in
[`../Software/src/`](../Software/src), and step 1 of
`tb_fmma` asserts that the CPU really does stay parked.

## 3.5 Reset

There are two sources, OR-ed together:

* **Power-on.** A 5-bit counter holds reset for 16 clocks after
  configuration, then releases it permanently.
* **`KEY[0]`.** The DE1-SoC push buttons are active low. Holding the button
  clears the counter, so the CPU is held in reset for as long as it is
  pressed plus 16 clocks. The button goes through two synchroniser flops
  before it reaches anything, because it is asynchronous to `CLOCK_50` and it
  bounces.

The original design had no external reset at all, which meant the only way to
restart the CPU was to reconfigure the FPGA. That is inconvenient for a demo
and makes per-test reset impossible in simulation, so `KEY[0]` was added.

The host has no reset line into the fabric — the bridge carries data, not
control — so software restart is done a third way, by the `CFG_RESTART` word
described in [07](07-shared-memory-protocol.md).

Note the polarity trap, which the code comments on: the register bank, PC, IR
and flag register take an **active-high** reset, while the control FSM takes
an **active-low** one. That is inherited from the original lab code.

## 3.6 Register bank

Sixteen 32-bit registers, each a plain enabled flip-flop array, all reset to
zero. There is no hardware zero register: `R0` holds zero only because the
program puts it there and never writes it. `trading.asm` starts with
`XOR R0, R0` so that holds even if a previous program left something else
behind.

Writes are one-hot: `Encoder4to16` turns `instrR[11:8]` plus the FSM's write
enable into a 16-bit enable vector. `CMP` is the only ALU operation that does
not write back, and the FSM suppresses the enable by looking at the *decoded*
opcode rather than the opcode register — which still holds the previous
instruction at that point in the cycle.

## 3.7 ALU

Combinational, 13 operations, five flags. The full table with semantics is in
[04-isa-reference](04-isa-reference.md) §4.5. Three things worth knowing at
this level:

* **The flag register is written for every R/I-type instruction**, including
  the logical operations, `MOV` and `MUL` — which produce no flags and
  therefore *clear* the flag register. A compare does not survive an
  intervening `MOV`. Put a `CMP` immediately before the branch that uses it.
* **`SUB` sets N from the sign of the result**, which differs from "A < B"
  exactly when the subtraction overflows. `CMP` computes a true signed
  comparison. Branch on `CMP`.
* **The carry input** comes from the flag register, so `ADDC`/`SUBC` can chain
  across instructions. It used to be tied to zero, which made `ADDC`
  identical to `ADD`.

## 3.8 Next-PC selection

`Disp` computes the next PC from a 2-bit selector the FSM drives:

| Selector | Next PC | Used by |
|----------|---------|---------|
| `00` | hold | reset and the halt state |
| `01` | `PC + 1` | everything sequential, and a branch that is not taken |
| `10` | `PC + sign_extend(instrR[7:0])` | a taken branch |
| `11` | `rAddr` | a taken jump |

The displacement is **signed and relative to the branch instruction's own
address**, because the PC has not been incremented yet when the adder runs.
The assembler computes `disp = target - branch_address` to match, and
`test_toolchain.test_branch_displacement_is_relative_to_the_branch` pins it
down.

Jumps take their target from a register and are absolute, truncated to the
10-bit address space. That is how `trading.asm` gets back to the top of a
loop that is further than 127 words away — it keeps the loop address in `R15`
and uses `JUC R15`.

## 3.9 Memory interface

One port, three uses:

```verilog
assign mem_addr  = (LS | we) ? rAddr[9:0] : pc_out;
assign mem_wdata = rSrc2;
assign mem_write = we;
```

`LS` is asserted for the load state and `we` for the store state, both for
exactly one cycle, so the address is the PC at every other moment. Byte
enables are tied high: this CPU only ever does whole-word accesses.

The other port of the RAM belongs to the host. The two ports are independent
and unarbitrated, which is what makes [07](07-shared-memory-protocol.md)
necessary.

## 3.10 Known limitations

These are real and are not worked around anywhere; they are listed so nobody
rediscovers them the hard way.

| Limitation | Consequence |
|------------|-------------|
| 3 cycles per instruction, no pipelining | The strategy loop costs 780 ns where a fixed-function pipeline would cost tens of nanoseconds. See [14](14-latency-and-performance.md) §14.6. |
| No hardware zero register | `R0` is a convention, enforced by the first instruction of the program. |
| Logical ops clear the flags | `CMP` must be adjacent to its branch. |
| Only six condition codes decoded | See [04](04-isa-reference.md) §4.4; the assembler rejects the rest. |
| Immediates are 24-bit and unsigned | A negative constant has to be built with `XOR`/`SUB`. |
| Branch displacement is ±127 words | Longer jumps need a register and `JUC`. |
| No multiply-accumulate, no divide, no barrel-shift-and-add | The strategy is written to need none of them; it compares a doubled mid so it never has to divide by two. |
| No stack, no call/return | The strategy is a flat loop. A subroutine would have to pass its return address in a register. |
