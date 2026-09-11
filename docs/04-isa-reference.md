# 4. ISA reference

This is the instruction set the RTL in `Code/` actually implements. The
machine-readable version is
[`../Software/fmma_isa.py`](../Software/fmma_isa.py), which the assembler and
the simulator are both built from; if this document and that file ever
disagree, the file is authoritative and this is a bug.

The ISA descends from the CR16-style set used in ECE 3710, but it is **not**
that set. Several encodings the textbook defines are not decoded by this
hardware, and the assembler refuses to emit them rather than producing
instructions that quietly do nothing. §4.4 is the list.

## 4.1 Programmer's model

| | |
|---|---|
| Registers | `R0`–`R15`, 32 bits, all general purpose |
| `R0` | zero by convention only — the program sets it and never writes it |
| Flags | Z, C, F, L, N (§4.5) |
| PC | 10 bits, word-addressed; resets to `FMMA_PROGRAM_BASE` (8) |
| Memory | 1024 words, word-addressed, shared with the host |
| Endianness | not applicable: the CPU only does whole-word accesses |

## 4.2 Instruction formats

`FSMtrial` dispatches on `instr[15:12]`. The upper 16 bits are only used by
the I-type immediate.

```
 31                    16 15    12 11     8 7      4 3      0
┌────────────────────────┬────────┬────────┬────────┬────────┐
│        unused          │  0000  │   rd   │   op   │   rs   │  R-type
├────────────────────────┼────────┼────────┼────────┼────────┤
│       imm[23:8]        │   op   │   rd   │    imm[7:0]     │  I-type
├────────────────────────┼────────┼────────┼────────┼────────┤
│        unused          │  0100  │   rd   │  0000  │   ra   │  LOAD
├────────────────────────┼────────┼────────┼────────┼────────┤
│        unused          │  0100  │   rs   │  0100  │   ra   │  STOR
├────────────────────────┼────────┼────────┼────────┼────────┤
│        unused          │  0100  │  cond  │  1100  │   rt   │  Jcc
├────────────────────────┼────────┼────────┼─────────────────┤
│        unused          │  1100  │  cond  │    disp[7:0]    │  Bcc
└────────────────────────┴────────┴────────┴────────┴────────┘

 0x00000000 = HALT: the CPU parks and polls this word until it changes.
```

The I-type opcode lives in `instr[15:12]`, which is also the format selector.
That is why opcode 0 (no operation) and opcode 4 are unavailable as I-type
operations: those bit patterns mean "R-type" and "load/store/jump". The ALU
opcode table skips them accordingly.

## 4.3 Instructions

### ALU operations

Both forms compute `Rd = Rd op X` and write the result to `Rd`.

| Mnemonic | op | R-type | I-type | Operation | Flags |
|----------|----|--------|--------|-----------|-------|
| `AND` | `0001` | ✓ | ✓ | bitwise and | cleared |
| `OR`  | `0010` | ✓ | ✓ | bitwise or | cleared |
| `XOR` | `0011` | ✓ | ✓ | bitwise xor | cleared |
| `ADD` | `0101` | ✓ | ✓ | signed add | Z, F, N |
| `ADDU`| `0110` | ✓ | ✓ | unsigned add | Z, C |
| `ADDC`| `0111` | ✓ | ✓ | add with carry in | Z, C, F, N |
| `LSH` | `1000` | ✓ | ✓ | logical shift, signed amount | cleared |
| `SUB` | `1001` | ✓ | ✓ | subtract | Z, C, F, L, N |
| `SUBC`| `1010` | ✓ | ✓ | subtract with borrow | Z, C, F, L, N |
| `CMP` | `1011` | ✓ | ✓ | compare, no write-back | Z, L, N |
| `ASH` | `1101` | ✓ | ✓ | arithmetic shift, signed amount | cleared |
| `MUL` | `1110` | ✓ | ✓ | low 32 bits of the product | cleared |
| `MOV` | `1111` | ✓ | ✓ | `Rd = X` | cleared |

Examples:

```
    ADD  R13, R7        ; R13 = R13 + R7
    SUB  R11, #3        ; R11 = R11 - 3
    MOV  R9,  R4        ; R9  = R4
    MOV  R8,  #100000   ; R8  = 100000
    CMP  R4,  R5        ; flags only
```

> **Historical note.** Before the 2026 datapath fix the immediate went to the
> ALU's A input instead of its B input, so every I-type instruction computed
> `imm op Rd`: `SUB Rd,#k` was `k - Rd`, `CMP Rd,#k` compared backwards, and
> `MOV Rd,#k` was a no-op. Only the commutative operations worked, which is
> why the old strategy code loaded every constant with `XOR Rd,Rd` followed
> by `OR Rd,#k`. `trading.asm` now probes for this at startup (§4.8).

**Shifts.** The amount is a *signed* 5-bit value in the low bits of the
second operand: positive shifts left, negative shifts right. `LSH` shifts in
zeros; `ASH` replicates the sign on a right shift. Useful range is −16…+15.

```
    LSH  R4, #4         ; R4 = R4 << 4
    LSH  R4, #0x1C      ; 0x1C = -4 in 5 bits -> R4 = R4 >> 4  (logical)
    ASH  R4, #0x1C      ; R4 = R4 >> 4  (arithmetic)
```

### Memory

| Mnemonic | Encoding | Operation |
|----------|----------|-----------|
| `LOAD Rd, Ra` | `0100 rd 0000 ra` | `Rd = RAM[Ra]` |
| `STOR Rs, Ra` | `0100 rs 0100 ra` | `RAM[Ra] = Rs` |

The address always comes from a register; there is no displacement or index
mode. Addresses are word indices and are truncated to 10 bits. To reach a
constant address, load it into a register first: `LDI R4, #SIGNAL`.

`LOAD Rd, Rd` is legal and is how `trading.asm` reads a value through an
address register it no longer needs.

### Branches (PC-relative, signed 8-bit displacement)

| Mnemonic | cond | Taken when | Meaning after `CMP a, b` |
|----------|------|------------|--------------------------|
| `BEQ` | `0000` | Z | `a == b` |
| `BNE` | `0001` | !Z | `a != b` |
| `BLT` | `0110` | N | `a < b`, signed |
| `BGE` | `0111` | Z or !N | `a >= b`, signed |
| `BLE` | `1101` | Z or N | `a <= b`, signed |
| `BUC` | `1110` | always | unconditional |

`BZ` and `BNZ` are accepted as aliases for `BEQ` and `BNE`.

The displacement is relative to the **branch's own address**, so `BUC 0` is an
infinite loop on itself and `BUC 1` is a no-op that costs three cycles (that
is what `NOP` assembles to). Range is −128…+127 words; the assembler computes
the displacement from a label and errors if it does not fit.

### Jumps (absolute, through a register)

| Mnemonic | Encoding | Operation |
|----------|----------|-----------|
| `Jcc Rt` | `0100 cond 1100 rt` | if the condition holds, `PC = Rt` |

Same six condition codes: `JEQ`, `JNE`, `JLT`, `JGE`, `JLE`, `JUC`.

## 4.4 Condition codes the hardware does **not** implement

`FSMtrial` decodes six condition codes. Anything else falls off the end of
its if/else chain, leaves the next-PC selector at "PC + 1", and is therefore
**never taken** — with no error, no warning and no way to notice except by
wondering why a branch never fires.

| Suffix | Textbook meaning | What this hardware does |
|--------|------------------|-------------------------|
| `GT` | signed greater than | not decoded — never taken |
| `CS`, `CC` | carry set / clear | not decoded — never taken |
| `HI`, `LS`, `LO`, `HS` | unsigned comparisons | not decoded — never taken |
| `FS`, `FC` | overflow set / clear | not decoded — never taken |
| code `1100` | textbook `LT` | decoded, but its expression `!Z or !N` is **true after every possible `CMP`**, so it is an unconditional branch with a conditional name |

The assembler rejects all of these with an explanation. For "greater than",
swap the operands of the compare:

```
    CMP  R5, R4
    BLT  target        ; taken when R4 > R5
```

Code `1100` was removed from the RTL decoder as part of the 2026 cleanup, so
it now behaves like the rest — not taken — instead of being a trap.

## 4.5 Flags

| Bit | Name | Meaning |
|-----|------|---------|
| 4 | Z | result was zero, or the compared values were equal |
| 3 | C | carry out (`ADDU`, `ADDC`) or **not** borrow (`SUB`, `SUBC`) |
| 2 | F | signed overflow |
| 1 | L | unsigned less-than |
| 0 | N | signed less-than (`CMP`) or the sign of the result (`ADD`, `SUB`) |

Only Z and N reach the branch decoder. C, F and L are computed and readable
only by a later `CMP` against a copy; no branch tests them.

Two behaviours to design around:

1. **Every R/I-type instruction writes the flag register**, so an operation
   that produces no flags clears it. `MOV`, `MUL`, `AND`, `OR`, `XOR`, `LSH`
   and `ASH` all destroy a pending compare. Keep `CMP` adjacent to its
   branch. `LOAD`, `STOR`, branches and jumps leave the flags alone.
2. **`SUB` sets N from the sign of the result**, which is not the same as
   "A < B" when the subtraction overflows. `CMP` does a true signed
   comparison and is what the strategy uses before every branch.

## 4.6 Assembler syntax

```
    label:                  a label, alone or in front of an instruction
    OP    Rd, Rs            R-type
    OP    Rd, #imm          I-type, immediate 0..0xFFFFFF
    LOAD  Rd, Ra
    STOR  Rs, Ra
    Bcc   label             or a literal signed displacement
    Jcc   Rt
    .include "file"         textual include (used for the memory map)
    .equ  NAME, value       named constant
    .word value             one literal data word
    %  comment              ';' also works; '#' only when not an operand
```

Pseudo-instructions:

| Written | Assembles to | Notes |
|---------|--------------|-------|
| `LDI Rd, #imm` | `MOV Rd, #imm` | one word |
| `NOP` | `BUC +1` | three cycles, does **not** touch the flags |

A label used as an immediate resolves to its **absolute** word address, which
is how a jump target gets into a register:

```
    LDI  R15, #LOOP
    ...
    JUC  R15
```

## 4.7 What the assembler refuses to do

Each of these would otherwise produce a program that assembles cleanly and
misbehaves at run time:

| Rejected | Reason |
|----------|--------|
| a condition code from §4.4 | the branch would never be taken |
| an instruction that encodes to `0x00000000` | that word is HALT, so the CPU would park there |
| a branch displacement outside −128…+127 | it would wrap to somewhere else |
| a negative immediate | the field is unsigned; build the value and use the R-type form |
| a program that does not fit in the program area | it would overwrite the input block |
| a duplicate label, an unknown mnemonic, `R16` | ordinary errors |

## 4.8 Bitstream/program compatibility

The immediate-operand fix (§4.3) lives in the bitstream, not in the program.
A program assembled against the fixed ISA would run on an old bitstream and
compute wrong numbers silently — which, for something that sends orders, is
the worst possible failure mode.

`trading.asm` therefore probes the datapath during initialisation:

```
    LDI  R8, #10
    SUB  R8, #3          ; 7 on a correct datapath, -7 on an old one
    LDI  R7, #7
    CMP  R8, R7
    BNE  ISA_MISMATCH
```

Only if the probe passes does the CPU write `FW_VERSION`, and the host loader
refuses to enable trading until it sees that word. On a mismatch the CPU
keeps its heartbeat running — so the host can tell it is alive — but never
publishes a version, and the loader prints the reason. `tb_fmma` step 2
checks the working case.

## 4.9 Worked example

The idle path of the strategy loop, 13 instructions and 39 cycles:

```
LOOP:
    ADD  R12, R1            ; heartbeat++
    STOR R12, R3            ; publish it
    LDI  R4, #CFG_RESTART   ; one address register serves two checks
    LOAD R8, R4
    CMP  R8, R0
    BNE  DO_RESTART
    ADD  R4, R1             ; R4 = &FILL_SEQ
    LOAD R8, R4
    CMP  R8, R14
    BEQ  NOFILL
    ...
NOFILL:
    LOAD R7, R2             ; TICK_SEQ
    CMP  R7, R11
    BEQ  LOOP               ; nothing new
```

Note `CMP` immediately before each branch, `LDI` used once and then advanced
with `ADD` rather than reloaded, and `R0` standing in for a zero comparand.
