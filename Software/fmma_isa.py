#!/usr/bin/env python3
"""FMMA instruction set architecture - single source of truth.

This module describes the ISA that is *actually implemented* by the RTL in
``Code/`` (``FSMTrial`` for decode and control, ``ALUFinal`` for arithmetic,
``disp`` for next-PC selection).  It is used by:

  * ``Assembler.py``      - to turn assembly into machine words
  * ``fmma_sim.py``       - the golden-reference instruction set simulator
  * ``test_assembler.py`` - the encoder/decoder round-trip tests

Whenever the RTL and this file disagree, the RTL wins and this file is a bug.
``docs/04-isa-reference.md`` is the prose version of everything below.

--------------------------------------------------------------------------
Instruction formats (32-bit words, as decoded by FSMTrial)
--------------------------------------------------------------------------

FSMTrial dispatches on ``instr[15:12]``:

  0000  R-type   0000 | rd[3:0] | op[3:0] | rs[3:0]        (upper 16 bits ignored)
  0100  memory / jump, sub-dispatch on instr[7:4]:
          0000  LOAD   0100 | rd[3:0]   | 0000 | ra[3:0]
          0100  STOR   0100 | rd[3:0]   | 0100 | ra[3:0]
          1100  Jcc    0100 | cond[3:0] | 1100 | rt[3:0]
  1100  Bcc      1100 | cond[3:0] | disp[7:0]
  else  I-type   imm[23:8] | op[3:0] | rd[3:0] | imm[7:0]

A word of all zeros is *not* a NOP: FSMTrial treats it as HALT and parks in
its ``hlt`` state, polling the word at the PC until it becomes non-zero.  That
behaviour is what makes the CPU self-starting (see docs/07).

--------------------------------------------------------------------------
Operand order
--------------------------------------------------------------------------

The ALU computes ``A op B`` and the result goes back to ``Rd``, so both forms
put ``R[rd]`` on the A input:

    OP Rd, Rs    ->  R[rd] = R[rd] op R[rs]
    OP Rd, #imm  ->  R[rd] = R[rd] op imm

This was not always true.  Until the 2026 fix the immediate was muxed onto the
*A* input instead of the B input, so every I-type instruction executed
``imm op R[rd]``: ``SUB Rd,#k`` computed ``k - Rd``, ``CMP Rd,#k`` compared the
two the wrong way round, and ``MOV Rd,#k`` was a no-op because MOV returns its
B input.  The strategy code of the day only ever used commutative immediates
(OR), so nothing visibly broke and the defect sat there.

Because the fix lives in the bitstream and not in the program, a new program
running on an old bitstream would compute silently wrong values.  The startup
block of ``trading.asm`` therefore probes the wiring (``SUB`` an immediate and
check the answer) before it writes ``FW_VERSION``, and the HPS loader refuses
to trade until that word appears.

--------------------------------------------------------------------------
The condition-code trap
--------------------------------------------------------------------------

MOST CONDITION CODES ARE NOT IMPLEMENTED.  FSMTrial decodes exactly six
condition codes; every other code falls through its if/else chain, leaves
``displaceControl`` at "PC+1" and is therefore *never taken* - silently.  The
assembler only accepts the implemented ones.  See ``CONDITIONS``.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# ALU opcodes - the 4-bit field decoded by ALUFinal
# ---------------------------------------------------------------------------

#: mnemonic -> 4-bit ALU opcode
ALU_OPCODES = {
    "AND":  0x1,
    "OR":   0x2,
    "XOR":  0x3,
    "ADD":  0x5,
    "ADDU": 0x6,
    "ADDC": 0x7,
    "LSH":  0x8,
    "SUB":  0x9,
    "SUBC": 0xA,
    "CMP":  0xB,
    "ASH":  0xD,
    "MUL":  0xE,
    "MOV":  0xF,
}

#: Operations that commute.  Kept because it documents which instructions
#: were unaffected by the pre-2026 operand-order defect, and because the
#: assembler uses it to phrase a warning when an old-style source is
#: assembled for an old bitstream.
COMMUTATIVE_OPS = {"AND", "OR", "XOR", "ADD", "ADDU", "MUL"}

#: Operations that write a result back into Rd.  CMP only sets flags
#: (FSMTrial keeps ``Ren`` low when the decoded opcode is CMP).
WRITES_RESULT = {m for m in ALU_OPCODES if m != "CMP"}

#: Operations that update the flag register.  FSMTrial asserts ``Fen`` for the
#: whole R/I-type class, so every ALU op writes the flags - but ALUFinal only
#: produces meaningful flags for the arithmetic ones.
SETS_FLAGS = set(ALU_OPCODES)

#: ALU ops whose flag output is meaningful (ALUFinal leaves Flags at 0 for the
#: logical ops and for MOV/MUL, which is a hardware quirk worth knowing).
MEANINGFUL_FLAGS = {"ADD", "ADDU", "ADDC", "SUB", "SUBC", "CMP"}


# ---------------------------------------------------------------------------
# Condition codes
# ---------------------------------------------------------------------------
#
# Flag register layout produced by ALUFinal:
#     Flags[4] = Z  zero
#     Flags[3] = C  carry
#     Flags[2] = F  overflow
#     Flags[1] = L  "low"  (unsigned less-than; ALUFinal computes this wrongly
#                           for mixed-sign operands - do not rely on it)
#     Flags[0] = N  negative / signed less-than
#
# After ``CMP A, B`` ALUFinal sets  Z = (A == B)  and  N = (A < B) signed.
#
# The table below lists what FSMTrial *actually* decodes.  The expression is
# written in terms of Z and N as they are after a CMP.

class _Cond:
    __slots__ = ("code", "name", "expr", "describe")

    def __init__(self, code, name, expr, describe):
        self.code = code
        self.name = name
        self.expr = expr            # callable(z, n) -> bool
        self.describe = describe

    def taken(self, z, n):
        return bool(self.expr(bool(z), bool(n)))


#: mnemonic suffix -> condition descriptor.  Only these seven are implemented
#: in hardware; the assembler refuses everything else.
CONDITIONS = {
    "EQ": _Cond(0b0000, "EQ", lambda z, n: z,            "equal            (Z)"),
    "NE": _Cond(0b0001, "NE", lambda z, n: not z,        "not equal        (!Z)"),
    "LT": _Cond(0b0110, "LT", lambda z, n: n,            "signed less than (N)"),
    "GE": _Cond(0b0111, "GE", lambda z, n: z or not n,   "signed >=        (Z | !N)"),
    "LE": _Cond(0b1101, "LE", lambda z, n: z or n,       "signed <=        (Z | N)"),
    "UC": _Cond(0b1110, "UC", lambda z, n: True,         "unconditional"),
}

#: Convenience aliases that assemble to an implemented condition.
COND_ALIASES = {
    "Z":  "EQ",
    "NZ": "NE",
}

#: Condition suffixes that appear in the ECE 3710 ISA document but that
#: FSMTrial does NOT decode.  Assembling one of these would emit a branch that
#: is never taken, so the assembler rejects them with this explanation.
UNIMPLEMENTED_CONDITIONS = {
    "GT": "hardware has no 'greater than' code; swap the CMP operands and use LT",
    "CS": "the carry flag is not routed to the branch decoder",
    "CC": "the carry flag is not routed to the branch decoder",
    "HI": "unsigned comparisons are not decoded; use LT/GE on signed values",
    "LS": "unsigned comparisons are not decoded; use LT/GE on signed values",
    "LO": "unsigned comparisons are not decoded; use LT/GE on signed values",
    "HS": "unsigned comparisons are not decoded; use LT/GE on signed values",
    "FS": "the overflow flag is not routed to the branch decoder",
    "FC": "the overflow flag is not routed to the branch decoder",
}

#: FSMTrial condition code 1100 is decoded, but its expression (!Z | !N) is
#: true for every possible CMP outcome, so it behaves as an unconditional
#: branch while reading like a conditional one.  Never emit it.
DEGENERATE_CONDITION_CODE = 0b1100


# ---------------------------------------------------------------------------
# Field positions
# ---------------------------------------------------------------------------

CLASS_RTYPE  = 0b0000     # instr[15:12]
CLASS_MEMJMP = 0b0100
CLASS_BRANCH = 0b1100

SUB_LOAD = 0b0000         # instr[7:4] when instr[15:12] == 0100
SUB_STOR = 0b0100
SUB_JUMP = 0b1100

WORD_BITS = 32
ADDR_BITS = 10            # the shared RAM is 1024 words deep
MEM_WORDS = 1 << ADDR_BITS
IMM_MAX = 0xFFFFFF        # I-type immediates are 24 bits (imm[23:16] is lost)
DISP_MIN = -128
DISP_MAX = 127


# ---------------------------------------------------------------------------
# Encoders
# ---------------------------------------------------------------------------

def _chk_reg(n, what="register"):
    if not isinstance(n, int) or not (0 <= n <= 15):
        raise ValueError(f"{what} out of range (0-15): {n}")
    return n


def encode_rtype(op, rd, rs):
    """``OP Rd, Rs``  ->  R[rd] = R[rd] op R[rs]."""
    if op not in ALU_OPCODES:
        raise ValueError(f"not an ALU opcode: {op}")
    return (_chk_reg(rd, "rd") << 8) | (ALU_OPCODES[op] << 4) | _chk_reg(rs, "rs")


def encode_itype(op, rd, imm):
    """``OP Rd, #imm``  ->  R[rd] = R[rd] op imm."""
    if op not in ALU_OPCODES:
        raise ValueError(f"not an ALU opcode: {op}")
    if not (0 <= imm <= IMM_MAX):
        raise ValueError(f"immediate {imm} out of range (0..0x{IMM_MAX:X})")
    upper = (imm >> 8) & 0xFFFF
    lower = imm & 0xFF
    return (upper << 16) | (ALU_OPCODES[op] << 12) | (_chk_reg(rd, "rd") << 8) | lower


def encode_load(rd, ra):
    """``LOAD Rd, Ra``  ->  R[rd] = RAM[R[ra]]."""
    return (CLASS_MEMJMP << 12) | (_chk_reg(rd, "rd") << 8) | (SUB_LOAD << 4) | _chk_reg(ra, "ra")


def encode_stor(rs, ra):
    """``STOR Rs, Ra``  ->  RAM[R[ra]] = R[rs]."""
    return (CLASS_MEMJMP << 12) | (_chk_reg(rs, "rs") << 8) | (SUB_STOR << 4) | _chk_reg(ra, "ra")


def encode_branch(cond, disp):
    """``Bcc disp``  ->  PC = PC + disp (signed, relative to the branch itself)."""
    c = _resolve_cond(cond)
    if not (DISP_MIN <= disp <= DISP_MAX):
        raise ValueError(f"branch displacement {disp} out of range ({DISP_MIN}..{DISP_MAX})")
    return (CLASS_BRANCH << 12) | (c.code << 8) | (disp & 0xFF)


def encode_jump(cond, rt):
    """``Jcc Rt``  ->  PC = R[rt] (absolute word address, low 10 bits)."""
    c = _resolve_cond(cond)
    return (CLASS_MEMJMP << 12) | (c.code << 8) | (SUB_JUMP << 4) | _chk_reg(rt, "rt")


def _resolve_cond(cond):
    if isinstance(cond, _Cond):
        return cond
    key = str(cond).upper()
    key = COND_ALIASES.get(key, key)
    if key in CONDITIONS:
        return CONDITIONS[key]
    if key in UNIMPLEMENTED_CONDITIONS:
        raise ValueError(
            f"condition '{key}' is not implemented by FSMTrial - a branch using "
            f"it would never be taken. {UNIMPLEMENTED_CONDITIONS[key]}")
    raise ValueError(f"unknown condition code: {cond}")


# ---------------------------------------------------------------------------
# Decoder - mirrors FSMTrial's decode state exactly
# ---------------------------------------------------------------------------

class Decoded:
    """The result of decoding one 32-bit word, in FSMTrial's terms."""

    __slots__ = ("word", "kind", "op", "rd", "rs", "ra", "rt", "imm",
                 "cond", "disp", "text")

    def __init__(self, **kw):
        for slot in self.__slots__:
            setattr(self, slot, kw.get(slot))

    def __repr__(self):
        return f"<Decoded 0x{self.word:08X} {self.text}>"


_OP_BY_CODE = {v: k for k, v in ALU_OPCODES.items()}
_COND_BY_CODE = {c.code: c for c in CONDITIONS.values()}


def decode(word):
    """Decode one machine word the way FSMTrial does.

    ``kind`` is one of: halt, rtype, itype, load, stor, jump, branch, undefined.

    'undefined' means FSMTrial's decode chain has no arm for this word.  That
    is not a harmless NOP: the state register keeps its value, so the CPU
    stalls in the decode state forever.  The assembler can never emit one, but
    a corrupted program word can produce one, which is why the simulator
    models it.
    """
    word &= 0xFFFFFFFF
    if word == 0:
        return Decoded(word=word, kind="halt", text="HALT (wait for a non-zero word)")

    cls = (word >> 12) & 0xF
    rd = (word >> 8) & 0xF

    if cls == CLASS_MEMJMP:
        sub = (word >> 4) & 0xF
        if sub == SUB_STOR:
            ra = word & 0xF
            return Decoded(word=word, kind="stor", rs=rd, ra=ra,
                           text=f"STOR R{rd}, R{ra}")
        if sub == SUB_LOAD:
            ra = word & 0xF
            return Decoded(word=word, kind="load", rd=rd, ra=ra,
                           text=f"LOAD R{rd}, R{ra}")
        if sub == SUB_JUMP:
            rt = word & 0xF
            cond = _COND_BY_CODE.get(rd)
            name = cond.name if cond else f"?{rd:04b}"
            return Decoded(word=word, kind="jump", cond=rd, rt=rt,
                           text=f"J{name} R{rt}")
        return Decoded(word=word, kind="undefined",
                       text=f"undefined 0100 form (instr[7:4]={sub:04b}) - CPU stalls")

    if cls == CLASS_BRANCH:
        raw = word & 0xFF
        disp = raw - 256 if raw & 0x80 else raw
        cond = _COND_BY_CODE.get(rd)
        name = cond.name if cond else f"?{rd:04b}"
        return Decoded(word=word, kind="branch", cond=rd, disp=disp,
                       text=f"B{name} {disp:+d}")

    if cls == CLASS_RTYPE:
        opc = (word >> 4) & 0xF
        rs = word & 0xF
        op = _OP_BY_CODE.get(opc, f"?{opc:X}")
        return Decoded(word=word, kind="rtype", op=op, rd=rd, rs=rs,
                       text=f"{op} R{rd}, R{rs}")

    # Everything else is an I-type; the opcode lives in instr[15:12].
    op = _OP_BY_CODE.get(cls, f"?{cls:X}")
    imm = (((word >> 16) & 0xFFFF) << 8) | (word & 0xFF)
    return Decoded(word=word, kind="itype", op=op, rd=rd, imm=imm,
                   text=f"{op} R{rd}, #{imm}")


# ---------------------------------------------------------------------------
# Timing model
# ---------------------------------------------------------------------------
#
# Every instruction runs fetch (S0) -> decode (S1) -> execute (S2..S6) and the
# FSM advances on each falling clock edge, so every instruction costs exactly
# three clock cycles.  The halt state costs one cycle per poll.
#
# Confirmed against RTL simulation: the steady-state strategy loop of
# trading.asm measures 68 cycles per iteration, which is 22 executed
# instructions plus the two-cycle branch-poll overhead.

CYCLES_PER_INSTRUCTION = 3
CYCLES_PER_HALT_POLL = 1
CLOCK_HZ = 50_000_000


def cycles_to_ns(cycles):
    return cycles * 1_000_000_000 / CLOCK_HZ
