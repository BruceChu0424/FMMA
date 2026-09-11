#!/usr/bin/env python3
"""Assembler for the FMMA CPU.

Turns an assembly source file into the images the rest of the system needs:

  fpga_program.hex   one 8-digit hex word per line  ($readmemh, simulation)
  fpga_program.bin   one 32-bit binary word per line (archive format)
  fpga_program.h     C array for the HPS loader in MarketStream.c
  fpga_program.mif   Quartus memory initialisation file for the on-chip RAM
  fpga_program.lst   annotated listing (source line -> address -> encoding)

The instruction encodings live in ``fmma_isa.py``, which is written against
the RTL in ``Code/``; this file is only the parser and the two-pass label
resolver.  ``docs/04-isa-reference.md`` is the prose reference.

Syntax
------
  label:                          a label, on its own line or before an insn
  OP    Rd, Rs                    R-type      Rd = Rd OP Rs
  OP    Rd, #imm                  I-type      Rd = Rd OP imm
  LOAD  Rd, Ra                    Rd = RAM[Ra]
  STOR  Rs, Ra                    RAM[Ra] = Rs
  Bcc   label | +/-disp           PC = PC + disp, relative to the branch
  Jcc   Rt                        PC = Rt (absolute word address)
  .equ  NAME, value               a named constant
  .word value                     one literal data word
  %  comment                      to end of line
  #  comment                      also accepted (a leading '#' on an operand
                                  is an immediate marker, not a comment)

Pseudo-instructions
-------------------
  LDI   Rd, #imm                  MOV Rd, #imm  (1 word; kept as a
                                  pseudo-instruction because "load
                                  immediate" is what it means)
  NOP                             BUC +1  (3 cycles, leaves the flags alone)

Both operand forms read the same way round: ``OP Rd, X`` computes
``Rd = Rd OP X``, whether X is a register or an immediate.  (That was not
true before the 2026 datapath fix - see fmma_isa for the history and for the
run-time probe that stops a new program running on an old bitstream.)

The assembler refuses to emit a condition code FSMTrial does not decode
(GT, CS, CC, HI, LS, LO, HS, FS, FC).  Those branches assemble fine on paper
and are then never taken, silently.

Usage
-----
  python Assembler.py trading.asm
  python Assembler.py market_maker.asm --base 8 --outdir . --prefix mm_program
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import fmma_isa as isa

REGISTER_RE = re.compile(r"^R(\d+)$", re.IGNORECASE)
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):$")


class AsmError(Exception):
    """An assembly error with a source location already formatted in."""


def _err(line_no, msg):
    raise AsmError(f"{line_no}: {msg}")


MAX_INCLUDE_DEPTH = 8


def read_source(path, _depth=0, _stack=()):
    """Read a source file and expand ``.include`` directives.

    Returns a list of ``(location, text)`` pairs, where location is a string
    like ``trading.asm:42`` so an error inside an include still points at the
    file the line actually came from.
    """
    path = Path(path)
    if _depth > MAX_INCLUDE_DEPTH:
        raise AsmError(f"{path.name}: .include nested more than "
                       f"{MAX_INCLUDE_DEPTH} deep")
    resolved = path.resolve()
    if resolved in _stack:
        raise AsmError(f"{path.name}: .include cycle")

    out = []
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        loc = f"{path.name}:{line_no}"
        stripped = strip_comment(raw)
        if stripped[:8].lower() == ".include":
            arg = stripped[8:].strip().strip('"').strip("'")
            if not arg:
                raise AsmError(f"{loc}: .include needs a file name")
            target = (path.parent / arg)
            if not target.is_file():
                raise AsmError(f"{loc}: cannot find included file '{arg}'")
            out.extend(read_source(target, _depth + 1, _stack + (resolved,)))
        else:
            out.append((loc, raw))
    return out


# ---------------------------------------------------------------------------
# Lexing helpers
# ---------------------------------------------------------------------------

def strip_comment(line):
    """Remove a trailing comment.

    '%' always starts a comment.  ';' does too.  '#' starts a comment only
    when it is not attached to an operand, so '#100' stays an immediate but
    '  # note' is dropped.
    """
    for i, ch in enumerate(line):
        if ch in "%;":
            return line[:i].strip()
        if ch == "#":
            # An immediate marker is preceded by ',' or whitespace and
            # followed by a value character.
            rest = line[i + 1:]
            if rest[:1] and (rest[0].isalnum() or rest[0] in "+-_"):
                continue
            return line[:i].strip()
    return line.strip()


def parse_register(token, line_no):
    m = REGISTER_RE.match(token.strip())
    if not m:
        _err(line_no, f"expected a register (R0-R15), got '{token}'")
    n = int(m.group(1))
    if not (0 <= n <= 15):
        _err(line_no, f"register out of range (R0-R15): '{token}'")
    return n


def is_register(token):
    return REGISTER_RE.match(token.strip()) is not None


def parse_value(token, symbols, line_no):
    """Parse '#123', '123', '0x40', '-4' or a symbol/label name."""
    tok = token.strip()
    if tok.startswith("#"):
        tok = tok[1:].strip()
    if tok in symbols:
        return symbols[tok]
    neg = False
    if tok.startswith(("+", "-")):
        neg = tok[0] == "-"
        tok = tok[1:]
    try:
        v = int(tok, 0)
    except ValueError:
        _err(line_no, f"'{token}' is neither a number nor a known symbol")
    return -v if neg else v


def split_operands(text):
    return [t for t in re.split(r"[,\s]+", text.strip()) if t]


# ---------------------------------------------------------------------------
# Pass 1 - expand pseudo-instructions, collect labels and constants
# ---------------------------------------------------------------------------

class Item:
    """One emitted word, before its operands are resolved."""

    __slots__ = ("line_no", "source", "mnemonic", "operands", "index", "literal")

    def __init__(self, line_no, source, mnemonic, operands, index, literal=None):
        self.line_no = line_no
        self.source = source
        self.mnemonic = mnemonic
        self.operands = operands
        self.index = index          # program-relative word index
        self.literal = literal      # set for .word


def first_pass(located_lines, base):
    """Return ``(symbols, items)``.

    ``located_lines`` is a list of ``(location, text)`` pairs as produced by
    :func:`read_source`.  ``symbols`` maps every label to its **absolute** word
    address (base + index) and every ``.equ`` name to its value, so a label can
    be used directly as an immediate jump target.
    """
    symbols = {}
    items = []
    index = 0
    pending_labels = []

    for line_no, raw in located_lines:
        line = strip_comment(raw)
        if not line:
            continue

        # A label may sit alone or in front of an instruction.
        while True:
            m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*", line)
            if not m:
                break
            name = m.group(1)
            if name in symbols or name in pending_labels:
                _err(line_no, f"duplicate label '{name}'")
            pending_labels.append(name)
            line = line[m.end():].strip()
        if not line:
            for name in pending_labels:
                symbols[name] = base + index
            pending_labels = []
            continue

        tokens = split_operands(line)
        mnemonic = tokens[0].upper()
        operands = tokens[1:]

        if mnemonic == ".EQU":
            if len(operands) != 2:
                _err(line_no, ".equ takes a name and a value")
            name = operands[0]
            if not name.isidentifier():
                _err(line_no, f"'{name}' is not a usable constant name")
            if name in symbols:
                _err(line_no, f"'{name}' is already defined")
            symbols[name] = parse_value(operands[1], symbols, line_no)
            continue

        # Labels in front of this instruction resolve to its address.
        for name in pending_labels:
            symbols[name] = base + index
        pending_labels = []

        if mnemonic == ".WORD":
            if len(operands) != 1:
                _err(line_no, ".word takes exactly one value")
            items.append(Item(line_no, line, ".WORD", operands, index))
            index += 1
            continue

        if mnemonic == "LDI":
            # Now that the I-type operand order is right, MOV Rd,#imm
            # really does load the immediate (MOV returns its B input),
            # so this is a single word rather than the XOR/OR pair the
            # old datapath forced.
            if len(operands) != 2:
                _err(line_no, "LDI takes a register and an immediate")
            if is_register(operands[1]):
                _err(line_no, "LDI takes an immediate; use MOV for a register")
            items.append(Item(line_no, line, "MOV", [operands[0], operands[1]], index))
            index += 1
            continue

        if mnemonic == "NOP":
            if operands:
                _err(line_no, "NOP takes no operands")
            items.append(Item(line_no, line, "BUC", ["1"], index))
            index += 1
            continue

        items.append(Item(line_no, line, mnemonic, operands, index))
        index += 1

    for name in pending_labels:
        symbols[name] = base + index      # a label at end of file

    return symbols, items


# ---------------------------------------------------------------------------
# Pass 2 - encode
# ---------------------------------------------------------------------------

def encode_item(item, symbols, base):
    m = item.mnemonic
    ops = item.operands
    ln = item.line_no

    if m == ".WORD":
        v = parse_value(ops[0], symbols, ln)
        if not (0 <= v <= 0xFFFFFFFF):
            _err(ln, f".word value {v} does not fit in 32 bits")
        return v

    if m in ("LOAD", "STOR"):
        if len(ops) != 2:
            _err(ln, f"{m} takes two registers")
        a = parse_register(ops[0], ln)
        b = parse_register(ops[1], ln)
        return isa.encode_load(a, b) if m == "LOAD" else isa.encode_stor(a, b)

    if m.startswith("B") and len(m) >= 2 and m != "BASE":
        suffix = m[1:]
        if len(ops) != 1:
            _err(ln, f"{m} takes one branch target")
        target = ops[0]
        if target in symbols:
            disp = symbols[target] - (base + item.index)
        else:
            disp = parse_value(target, symbols, ln)
        try:
            return isa.encode_branch(suffix, disp)
        except ValueError as e:
            _err(ln, str(e))

    if m.startswith("J"):
        suffix = m[1:]
        if len(ops) != 1:
            _err(ln, f"{m} takes one register holding the target address")
        rt = parse_register(ops[0], ln)
        try:
            return isa.encode_jump(suffix, rt)
        except ValueError as e:
            _err(ln, str(e))

    if m in isa.ALU_OPCODES:
        if len(ops) != 2:
            _err(ln, f"{m} takes a destination and a source")
        rd = parse_register(ops[0], ln)
        if is_register(ops[1]):
            return isa.encode_rtype(m, rd, parse_register(ops[1], ln))
        imm = parse_value(ops[1], symbols, ln)
        if imm < 0:
            _err(ln, f"negative immediate {imm}: the I-type field is unsigned. "
                     f"Build the value with LDI and use an R-type SUB instead.")
        try:
            return isa.encode_itype(m, rd, imm)
        except ValueError as e:
            _err(ln, str(e))

    _err(ln, f"unknown instruction '{m}'")


def assemble_file(src_path, base=8):
    """Assemble ``src_path`` (expanding .include).

    Returns ``(symbols, machine_code, items)``.
    """
    return _assemble(read_source(src_path), base)


def assemble_lines(lines, base=8):
    """Assemble a list of plain source lines (used by the tests)."""
    located = [(f"line {n}", text) for n, text in enumerate(lines, 1)]
    return _assemble(located, base)


def _assemble(located_lines, base):
    symbols, items = first_pass(located_lines, base)
    code = [encode_item(it, symbols, base) for it in items]

    for it, word in zip(items, code):
        if word == 0:
            _err(it.line_no,
                 "this instruction encodes to 0x00000000, which the hardware "
                 "treats as HALT (the CPU would park here waiting for the word "
                 "to change)")
    return symbols, code, items


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def _write(path, text):
    """Write a generated file with LF line endings on every platform.

    Without an explicit newline argument Python translates line endings
    to CRLF on Windows, so the same assembler run produces different
    bytes on the development PC and on the board. `make check-generated`
    then fails on line endings instead of on the thing it exists to
    catch, which is a hand-edited generated file.
    """
    Path(path).write_text(text, encoding="ascii", newline="\n")


def write_outputs(outdir, prefix, base, code, items, symbols, mem_words=isa.MEM_WORDS):
    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    _write(outdir / f"{prefix}.bin", "".join(f"{w:032b}\n" for w in code))
    _write(outdir / f"{prefix}.hex", "".join(f"{w:08x}\n" for w in code))

    h = [
        f"// Auto-generated by Assembler.py. Do not edit.",
        f"// Source program: {len(code)} words loaded at word address {base}.",
        "#ifndef FPGA_PROGRAM_H",
        "#define FPGA_PROGRAM_H",
        "",
        f"#define FPGA_PROGRAM_BASE {base}u",
        f"#define FPGA_PROGRAM_LEN  {len(code)}u",
        "",
        f"static const unsigned int fpga_program[FPGA_PROGRAM_LEN] = {{",
    ]
    for i, w in enumerate(code):
        comma = "," if i + 1 < len(code) else ""
        h.append(f"    0x{w:08X}u{comma}   /* word {base + i} */")
    h += ["};", "", "#endif /* FPGA_PROGRAM_H */", ""]
    _write(outdir / f"{prefix}.h", "\n".join(h))

    # Quartus MIF: the whole 1024-word RAM, program in place, everything else
    # zero.  Zero matters - a zero word is the CPU's halt instruction, so the
    # unused RAM must not contain junk.
    mif = [
        f"-- Auto-generated by Assembler.py. Do not edit.",
        f"-- On-chip RAM image: {len(code)} program words at word {base}.",
        f"DEPTH = {mem_words};",
        "WIDTH = 32;",
        "ADDRESS_RADIX = DEC;",
        "DATA_RADIX = HEX;",
        "CONTENT",
        "BEGIN",
    ]
    end = base + len(code)
    if base > 0:
        mif.append(f"    [0..{base - 1}] : 00000000;")
    for i, w in enumerate(code):
        mif.append(f"    {base + i} : {w:08X};")
    if end < mem_words:
        mif.append(f"    [{end}..{mem_words - 1}] : 00000000;")
    mif += ["END;", ""]
    _write(outdir / f"{prefix}.mif", "\n".join(mif))

    lst = [
        f"FMMA assembler listing - {len(code)} words at base {base}",
        "",
        "Symbols:",
    ]
    for name, value in sorted(symbols.items(), key=lambda kv: kv[1]):
        lst.append(f"    {name:<20} = {value}")
    lst += ["", "Code:", ""]
    for it, w in zip(items, code):
        d = isa.decode(w)
        lst.append(f"  {base + it.index:4d}  0x{w:08X}  {d.text:<28}  ; {it.source}")
    lst.append("")
    _write(outdir / f"{prefix}.lst", "\n".join(lst))


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def resolve_source_path(filename):
    raw = Path(filename)
    if ".." in raw.parts:
        raise AsmError(f"path traversal is not allowed: {filename}")
    src = raw.resolve()
    if not src.is_file():
        raise AsmError(f"source file not found: {filename}")
    return src


def main(argv=None):
    p = argparse.ArgumentParser(description="FMMA CPU assembler")
    p.add_argument("filename", help="assembly source, e.g. trading.asm")
    p.add_argument("--base", type=int, default=8,
                   help="word address the program is loaded at (default 8)")
    p.add_argument("--outdir", default=".", help="output directory (default .)")
    p.add_argument("--prefix", default="fpga_program",
                   help="output file stem (default fpga_program)")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args(argv)

    try:
        src = resolve_source_path(args.filename)
        symbols, code, items = assemble_file(src, args.base)
    except AsmError as e:
        print(f"{args.filename}: error: {e}", file=sys.stderr)
        return 1

    if args.base + len(code) > isa.MEM_WORDS:
        print(f"error: program does not fit: {len(code)} words at base "
              f"{args.base} exceeds the {isa.MEM_WORDS}-word RAM", file=sys.stderr)
        return 1

    write_outputs(args.outdir, args.prefix, args.base, code, items, symbols)

    if not args.quiet:
        print(f"Symbols ({len(symbols)}):")
        for name, value in sorted(symbols.items(), key=lambda kv: kv[1]):
            print(f"  {name:<20} = {value}")
        print("\nListing:")
        for it, w in zip(items, code):
            print(f"  {args.base + it.index:4d}: 0x{w:08X}  "
                  f"{isa.decode(w).text:<28}  ; {it.source}")
        print(f"\nWrote {args.prefix}.hex/.bin/.h/.mif/.lst to {args.outdir} "
              f"({len(code)} words at base {args.base})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
