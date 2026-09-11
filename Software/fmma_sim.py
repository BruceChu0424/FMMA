#!/usr/bin/env python3
"""Golden-reference instruction set simulator for the FMMA CPU.

This is a behavioural model of the CPU in ``Code/`` written against the same
ISA description the assembler uses (``fmma_isa.py``).  It exists for three
reasons:

  1. Strategy development.  Iterating on ``trading.asm`` against RTL
     simulation costs seconds per run; here it costs milliseconds, so the
     strategy test suite (``test_strategy.py``) can cover hundreds of market
     scenarios instead of the four the RTL testbench has time for.
  2. Co-simulation.  ``Testbenches/tb_isa.v`` runs the same programs on the
     RTL and the results are compared against this model, so a divergence
     between the two is a hard test failure rather than something nobody
     notices.
  3. Documentation.  The ALU here is a line-by-line transcription of
     ``ALUFinal``, including the parts that are wrong, so the quirks are
     written down somewhere executable.

Timing: the control FSM spends fetch/decode/execute on three successive
falling clock edges, so every instruction costs exactly 3 cycles and each
poll of the halt state costs 1.  Measured against RTL simulation, the
steady-state loop of ``trading.asm`` is 68 cycles in both models.

Usage:
    python fmma_sim.py trading.asm            # assemble and trace
    python fmma_sim.py --hex fpga_program.hex --max-instr 500
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import fmma_isa as isa

MASK32 = 0xFFFFFFFF
MASK10 = 0x3FF


def _u32(v):
    return v & MASK32


def _s32(v):
    v &= MASK32
    return v - (1 << 32) if v & 0x80000000 else v


class Flags:
    """The 5-bit flag register: {Z, C, F, L, N} = Flags[4:0]."""

    __slots__ = ("z", "c", "f", "l", "n")

    def __init__(self):
        self.z = self.c = self.f = self.l = self.n = 0

    def clear(self):
        self.z = self.c = self.f = self.l = self.n = 0

    def as_int(self):
        return (self.z << 4) | (self.c << 3) | (self.f << 2) | (self.l << 1) | self.n

    def load(self, v):
        self.z = (v >> 4) & 1
        self.c = (v >> 3) & 1
        self.f = (v >> 2) & 1
        self.l = (v >> 1) & 1
        self.n = v & 1

    def __repr__(self):
        return f"Z={self.z} C={self.c} F={self.f} L={self.l} N={self.n}"


# ---------------------------------------------------------------------------
# ALU - transcription of Code/ALUFinal
# ---------------------------------------------------------------------------

def alu(op, a, b, cin=0, legacy_shifts=False):
    """Return ``(result, flags)`` for one ALU operation.

    ``a`` is the A input (Rd for R-type, the immediate for I-type) and ``b``
    is the B input (Rs for R-type, Rd for I-type - see fmma_isa for why).

    ALUFinal starts every evaluation with ``C = 0; Flags = 0``, so any flag an
    operation does not explicitly assign reads back as zero.  That is why the
    logical operations and MOV/MUL clear the flag register instead of leaving
    it alone: the control FSM asserts Fen for the whole R/I-type class.
    """
    a = _u32(a)
    b = _u32(b)
    fl = Flags()

    if op == "AND":
        return a & b, fl
    if op == "OR":
        return a | b, fl
    if op == "XOR":
        return a ^ b, fl
    if op == "MOV":
        return b, fl
    if op == "MUL":
        return _u32(a * b), fl

    if op == "ADDU":
        total = a + b
        res = _u32(total)
        fl.c = 1 if total > MASK32 else 0
        fl.z = 1 if res == 0 else 0
        return res, fl

    if op == "ADD":
        res = _u32(a + b)
        fl.z = 1 if res == 0 else 0
        sa, sb, sr = (a >> 31) & 1, (b >> 31) & 1, (res >> 31) & 1
        fl.f = 1 if ((not sa and not sb and sr) or (sa and sb and not sr)) else 0
        fl.n = sr
        return res, fl

    if op == "ADDC":
        total = a + b + (cin & 1)
        res = _u32(total)
        fl.c = 1 if total > MASK32 else 0
        fl.z = 1 if res == 0 else 0
        bcin = _u32(b + (cin & 1))
        sa, sb, sr = (a >> 31) & 1, (bcin >> 31) & 1, (res >> 31) & 1
        fl.f = 1 if ((not sa and not sb and sr) or (sa and sb and not sr)) else 0
        fl.n = sr
        return res, fl

    if op == "SUB":
        res = _u32(a - b)
        fl.z = 1 if res == 0 else 0
        fl.c = 0 if a < b else 1          # borrow-inverted, as in ALUFinal
        sa, sb, sr = (a >> 31) & 1, (b >> 31) & 1, (res >> 31) & 1
        fl.f = 1 if ((sa ^ sb) and (sa ^ sr)) else 0
        fl.l = 1 if a < b else 0          # unsigned less-than
        fl.n = sr                         # sign of the difference
        return res, fl

    if op == "SUBC":
        bcin = _u32(b + (1 - (cin & 1)))
        res = _u32(a - bcin)
        fl.z = 1 if res == 0 else 0
        fl.c = 0 if a < bcin else 1       # borrow-inverted, same as SUB
        sa, sb, sr = (a >> 31) & 1, (bcin >> 31) & 1, (res >> 31) & 1
        fl.f = 1 if ((sa ^ sb) and (sa ^ sr)) else 0
        fl.l = 1 if a < bcin else 0
        fl.n = sr
        return res, fl

    if op == "CMP":
        # CMP produces no result, only flags.  Z is plain equality; N is the
        # signed less-than that every conditional branch is built on; L is the
        # unsigned less-than.
        fl.z = 1 if a == b else 0
        fl.n = 1 if _s32(a) < _s32(b) else 0
        fl.l = 1 if a < b else 0
        return 0, fl

    if op in ("LSH", "ASH"):
        sa5 = b & 0x1F
        amount = sa5 - 32 if sa5 & 0x10 else sa5   # signed 5-bit shift count
        if legacy_shifts:
            return _legacy_shift(op, a, sa5), fl
        if amount >= 0:
            return _u32(a << amount), fl
        if op == "LSH":
            return _u32(a >> (-amount)), fl
        return _u32(_s32(a) >> (-amount)), fl

    # Unknown opcode: ALUFinal's default arm holds C and clears the flags.
    return 0, fl


def _legacy_shift(op, a, sa5):
    """The pre-2026 ALUFinal shift behaviour, kept for regression comparison.

    The original code always performed the left shift, then computed
    ``shift = (-sa5) mod 32`` and, when that landed at 15 or below, performed
    a *second*, right shift on the already-shifted value.  The result is
    correct only for shift counts 1..16; a count of 0 returns ``a >> 1`` and
    every "negative" count (17..31) returns ``(a << sa5) >> k`` instead of
    ``a >> (32 - sa5)``.
    """
    c = _u32(a << sa5)
    shift = (-sa5) & 0x1F
    if shift > 15:
        return c
    if op == "LSH":
        return _u32(c >> ((sa5 + 1) & 0x1F))
    return _u32(c >> shift)


# ---------------------------------------------------------------------------
# The CPU
# ---------------------------------------------------------------------------

class HaltForever(Exception):
    """Raised by run() when the CPU parks in its halt state with nothing to do."""


class Cpu:
    """A cycle-counting model of the FMMA CPU and its 1024-word shared RAM."""

    def __init__(self, mem=None, pc=8, legacy_shifts=False):
        self.regs = [0] * 16
        self.flags = Flags()
        self.pc = pc & MASK10
        self.mem = list(mem) if mem is not None else [0] * isa.MEM_WORDS
        if len(self.mem) < isa.MEM_WORDS:
            self.mem += [0] * (isa.MEM_WORDS - len(self.mem))
        self.cycles = 0
        self.instructions = 0
        self.halted_polls = 0
        self.legacy_shifts = legacy_shifts
        self.trace = None          # set to a list to record an execution trace

    # -- memory helpers, also used by the "HPS" side of a test ---------------

    def read(self, word_addr):
        return self.mem[word_addr & MASK10]

    def write(self, word_addr, value):
        self.mem[word_addr & MASK10] = _u32(value)

    def load_program(self, words, base=8):
        for i, w in enumerate(words):
            self.mem[(base + i) & MASK10] = _u32(w)

    # -- execution -----------------------------------------------------------

    def step(self):
        """Execute one instruction (or one halt poll).  Returns the Decoded."""
        word = self.mem[self.pc]
        d = isa.decode(word)

        if d.kind == "halt":
            self.cycles += isa.CYCLES_PER_HALT_POLL
            self.halted_polls += 1
            return d

        if self.trace is not None:
            self.trace.append((self.pc, word, d.text))

        self.cycles += isa.CYCLES_PER_INSTRUCTION
        self.instructions += 1
        next_pc = (self.pc + 1) & MASK10

        if d.kind == "rtype":
            a = self.regs[d.rd]
            b = self.regs[d.rs]
            res, fl = alu(d.op, a, b, legacy_shifts=self.legacy_shifts)
            self.flags = fl                      # Fen is asserted for R/I-type
            if d.op in isa.WRITES_RESULT:
                self.regs[d.rd] = res

        elif d.kind == "itype":
            # R[rd] on the A input, the immediate on B - same order as the
            # R-type form, so 'SUB Rd, #k' really is Rd - k.
            a = self.regs[d.rd]
            b = d.imm
            res, fl = alu(d.op, a, b, legacy_shifts=self.legacy_shifts)
            self.flags = fl
            if d.op in isa.WRITES_RESULT:
                self.regs[d.rd] = res

        elif d.kind == "load":
            self.regs[d.rd] = self.mem[self.regs[d.ra] & MASK10]

        elif d.kind == "stor":
            self.mem[self.regs[d.ra] & MASK10] = _u32(self.regs[d.rs])

        elif d.kind == "branch":
            cond = isa._COND_BY_CODE.get(d.cond)
            taken = cond.taken(self.flags.z, self.flags.n) if cond else False
            if taken:
                next_pc = (self.pc + d.disp) & MASK10

        elif d.kind == "jump":
            cond = isa._COND_BY_CODE.get(d.cond)
            taken = cond.taken(self.flags.z, self.flags.n) if cond else False
            if taken:
                next_pc = self.regs[d.rt] & MASK10

        elif d.kind == "undefined":
            # FSMTrial leaves its state register untouched for this word, so
            # the real CPU stalls in decode and never fetches again.
            raise HaltForever(
                f"undefined instruction 0x{word:08X} at word {self.pc}: "
                f"the hardware stalls in its decode state here")

        self.pc = next_pc
        return d

    def run(self, max_instructions=100_000, max_halt_polls=100_000, on_step=None):
        """Execute up to ``max_instructions`` instructions *in this call*.

        The budget is per call, not cumulative, so a test can drive the CPU in
        stages: run, poke a "HPS" word, run again.

        ``on_step(cpu, decoded)`` is called after each step, which is the other
        way tests inject writes part way through a run.
        """
        executed = 0
        polls = 0
        while executed < max_instructions:
            d = self.step()
            if d.kind == "halt":
                polls += 1
                if polls > max_halt_polls:
                    raise HaltForever(f"CPU stuck in halt at word {self.pc}")
            else:
                polls = 0
                executed += 1
            if on_step is not None:
                on_step(self, d)
        return executed

    def run_until(self, predicate, max_instructions=200_000):
        """Run until ``predicate(cpu)`` is true; returns the cycles it took."""
        start = self.cycles
        for _ in range(max_instructions):
            if predicate(self):
                return self.cycles - start
            self.step()
        raise TimeoutError("predicate never became true")

    # -- convenience ---------------------------------------------------------

    def dump_regs(self):
        return "  ".join(f"R{i}={self.regs[i]}" for i in range(16))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def _load_hex(path):
    words = []
    for line in Path(path).read_text().split():
        words.append(int(line, 16))
    return words


def main(argv=None):
    p = argparse.ArgumentParser(description="FMMA instruction set simulator")
    src = p.add_mutually_exclusive_group(required=True)
    src.add_argument("source", nargs="?", help="assembly source to assemble and run")
    src.add_argument("--hex", help="pre-assembled .hex image (one word per line)")
    p.add_argument("--base", type=int, default=8, help="load address (default 8)")
    p.add_argument("--max-instr", type=int, default=400)
    p.add_argument("--trace", action="store_true", help="print every instruction")
    p.add_argument("--set", action="append", default=[], metavar="WORD=VALUE",
                   help="pre-load a RAM word, e.g. --set 64=1000000000")
    p.add_argument("--show", action="append", default=[], metavar="WORD",
                   help="print a RAM word at the end")
    args = p.parse_args(argv)

    if args.hex:
        words = _load_hex(args.hex)
    else:
        import Assembler
        _, words, _ = Assembler.assemble_file(Path(args.source).resolve(), args.base)

    cpu = Cpu(pc=args.base)
    cpu.load_program(words, args.base)
    for item in args.set:
        k, v = item.split("=", 1)
        cpu.write(int(k, 0), int(v, 0))
    if args.trace:
        cpu.trace = []

    try:
        cpu.run(max_instructions=args.max_instr)
    except HaltForever as e:
        print(f"[sim] {e}")

    if cpu.trace is not None:
        for pc, word, text in cpu.trace:
            print(f"  {pc:4d}: 0x{word:08X}  {text}")

    print(f"\n{cpu.instructions} instructions, {cpu.cycles} cycles "
          f"({isa.cycles_to_ns(cpu.cycles):.0f} ns at {isa.CLOCK_HZ/1e6:.0f} MHz), "
          f"{cpu.halted_polls} halt polls")
    print(f"PC = {cpu.pc}   flags {cpu.flags}")
    print(cpu.dump_regs())
    for w in args.show:
        addr = int(w, 0)
        print(f"RAM[{addr}] = {cpu.read(addr)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
