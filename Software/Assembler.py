#!/usr/bin/env python3
"""FMMA assembler for the custom 32-bit RISC CPU (ECE 3710 group 1011 ISA).

Instruction encodings (see Documents/PROTOCOL.md):

  R-type :  0000 <rd:4>   <op:4>    <rs:4>       upper 16 bits unused
  I-type :  <imm[23:8]>   <op:4>    <rd:4>  <imm[7:0]>
  LOAD   :  0100 <rd:4>   0000 <raddr:4>
  STOR   :  0100 <rdata:4> 0100 <raddr:4>
  BRANCH :  1100 <cond:4> <disp:8>            disp is relative to the branch
  JUMP   :  0100 <cond:4> 1100 <rtarget:4>    absolute target read from a register

Branch condition codes implemented in hardware (FSMTrial):
  EQ=0000 NE=0001 GT=0110 (taken when N=1, i.e. after CMP a,b when a<b)
  GE=1101 (Z=1 or N=1)   UC=1110 (always)

A 32'b0 word parks the CPU in its halt/wait state, so programs must not
contain all-zero instructions.

Outputs (fixed names, written to the current working directory):
  fpga_program.bin  one binary 32-bit word per line (legacy)
  fpga_program.hex  one 8-digit hex word per line, for $readmemh
  fpga_program.h    C header with the program as a const array
                    for the HPS loader (MarketStream.c)

Usage:
  python Assembler.py trading.asm [--base 8]
"""

import argparse
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Opcode table
# ---------------------------------------------------------------------------

OPCODES = {
    # ALU (R-type and I-type forms)
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

    # Memory
    "LOAD": 0x40,
    "STOR": 0x44,

    # Branches: condition code in bits [11:8], displacement in [7:0]
    "BEQ": 0xC0,
    "BNE": 0xC1,
    "BCS": 0xC2,
    "BCC": 0xC3,
    "BHI": 0xC4,
    "BLS": 0xC5,
    "BGT": 0xC6,
    "BLE": 0xC7,
    "BFS": 0xC8,
    "BFC": 0xC9,
    "BLO": 0xCA,
    "BHS": 0xCB,
    "BLT": 0xCC,
    "BGE": 0xCD,
    "BUC": 0xCE,

    # Jumps: condition code in bits [11:8], target register in [3:0]
    "JEQ": 0x40C,
    "JCS": 0x42C,
    "JCC": 0x43C,
    "JHI": 0x44C,
    "JLS": 0x45C,
    "JGT": 0x46C,
    "JLE": 0x47C,
    "JFS": 0x48C,
    "JFC": 0x49C,
    "JLO": 0x4AC,
    "JHS": 0x4BC,
    "JLT": 0x4CC,
    "JGE": 0x4DC,
    "JUC": 0x4EC,
}

ALU_MNEMONICS = {
    "AND", "OR", "XOR", "ADD", "ADDU", "ADDC", "LSH",
    "SUB", "SUBC", "CMP", "ASH", "MUL", "MOV",
}
BRANCH_MNEMONICS = {m for m in OPCODES if m.startswith("B")}
JUMP_MNEMONICS = {m for m in OPCODES if m.startswith("J")}

REGISTER_PATTERN = re.compile(r"R(\d+)$", re.IGNORECASE)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def parse_register(token):
    """Parse a register like 'R0'..'R15' and return its number."""
    m = REGISTER_PATTERN.match(token)
    if not m:
        raise ValueError(f"Invalid register: {token}")
    n = int(m.group(1))
    if not (0 <= n <= 15):
        raise ValueError(f"Register out of range (0-15): R{n}")
    return n


def is_register(token):
    return REGISTER_PATTERN.match(token) is not None


def strip_comment(line):
    """Remove everything after '%'."""
    return line.split("%", 1)[0].strip()


def parse_immediate(token, labels):
    """Parse '#123', '123', '0x7F' or a label (its absolute address)."""
    tok = token.strip()
    if tok.startswith("#"):
        tok = tok[1:]
    if tok in labels:
        return labels[tok]
    try:
        return int(tok, 0)
    except ValueError:
        raise ValueError(f"Invalid immediate or unknown label: {token}")


def resolve_source_path(filename):
    """Return the normalized absolute path of the input assembly file.

    Reject '..' components up front; the file is only ever read, and
    all generated outputs use fixed names in the current directory.
    """
    raw = Path(filename)
    if ".." in raw.parts:
        raise ValueError(f"Path traversal is not allowed: {filename}")
    src = raw.resolve()
    if not src.is_file():
        raise ValueError(f"Source file not found: {filename}")
    return src


# ---------------------------------------------------------------------------
# Pass 1: labels and instruction list
# ---------------------------------------------------------------------------

def first_pass(lines):
    """Return (labels, instruction_lines).

    labels maps label -> program index (0 based, before the load base).
    instruction_lines is a list of (source_line_no, text).
    """
    labels = {}
    instruction_lines = []
    pc = 0

    for i, raw in enumerate(lines):
        line = strip_comment(raw)
        if not line:
            continue

        if line.endswith(":"):
            label = line[:-1].strip()
            if not label.isidentifier():
                raise ValueError(f"Invalid label name on line {i + 1}: {label}")
            if label in labels:
                raise ValueError(f"Duplicate label '{label}' on line {i + 1}")
            labels[label] = pc
        else:
            instruction_lines.append((i + 1, line))
            pc += 1

    return labels, instruction_lines


# ---------------------------------------------------------------------------
# Pass 2: encoders
# ---------------------------------------------------------------------------

def jump_instruction(tokens, opcode, line_no):
    """Jcc Rtarget - absolute jump; the target address is read from a register."""
    if len(tokens) != 2:
        raise ValueError(f"Jump expects 1 register operand on line {line_no}")
    r_target = parse_register(tokens[1])
    return ((opcode & 0xFFF) << 4) | (r_target & 0xF)


def branch_instruction(tokens, opcode, line_no, pc, labels):
    """Bcc label | Bcc number.

    A label assembles to a displacement relative to this instruction
    (disp = label_index - pc). A plain number is used verbatim as the
    displacement, which allows hand-written relative branches.
    """
    if len(tokens) != 2:
        raise ValueError(f"Branch expects 1 operand on line {line_no}")

    tok = tokens[1]
    if tok in labels:
        disp = labels[tok] - pc
    else:
        try:
            disp = int(tok, 0)
        except ValueError:
            raise ValueError(
                f"Unknown branch target '{tok}' on line {line_no}")

    if not (-128 <= disp <= 127):
        raise ValueError(
            f"Branch displacement {disp} out of range (-128..127) "
            f"on line {line_no}")
    return ((opcode & 0xFF) << 8) | (disp & 0xFF)


def load_instruction(tokens, opcode, line_no):
    """LOAD Rd, Ra -> Rd = RAM[Ra]."""
    if len(tokens) != 3:
        raise ValueError(f"LOAD expects 2 operands on line {line_no}")
    rd = parse_register(tokens[1])
    ra = parse_register(tokens[2])
    return (((opcode >> 4) & 0xF) << 12) | (rd << 8) | ((opcode & 0xF) << 4) | ra


def store_instruction(tokens, opcode, line_no):
    """STOR Rs, Ra -> RAM[Ra] = Rs."""
    if len(tokens) != 3:
        raise ValueError(f"STOR expects 2 operands on line {line_no}")
    rs = parse_register(tokens[1])
    ra = parse_register(tokens[2])
    return (((opcode >> 4) & 0xF) << 12) | (rs << 8) | ((opcode & 0xF) << 4) | ra


def alu_instruction(tokens, opcode, line_no, labels):
    """OP Rd, Rs (R-type) or OP Rd, #imm (I-type, 24-bit immediate)."""
    if len(tokens) != 3:
        raise ValueError(f"ALU op expects 2 operands on line {line_no}")
    rd = parse_register(tokens[1])

    if is_register(tokens[2]):
        rs = parse_register(tokens[2])
        return (rd << 8) | (opcode << 4) | rs

    imm = parse_immediate(tokens[2], labels)
    if not (0 <= imm <= 0xFFFFFF):
        raise ValueError(
            f"Immediate {imm} out of range (0..0xFFFFFF) on line {line_no}")
    upper_imm = (imm >> 8) & 0xFFFF
    lower_imm = imm & 0xFF
    return (upper_imm << 16) | (opcode << 12) | (rd << 8) | lower_imm


def assemble_instruction(line_no, line, pc, labels):
    """Convert one instruction to its 32-bit machine word."""
    tokens = [t for t in re.split(r"[,\s]+", line.strip()) if t]
    if not tokens:
        return None

    mnemonic = tokens[0].upper()
    if mnemonic not in OPCODES:
        raise ValueError(f"Unknown instruction '{mnemonic}' on line {line_no}")
    opcode = OPCODES[mnemonic]

    if mnemonic == "LOAD":
        return load_instruction(tokens, opcode, line_no)
    if mnemonic == "STOR":
        return store_instruction(tokens, opcode, line_no)
    if mnemonic in BRANCH_MNEMONICS:
        return branch_instruction(tokens, opcode, line_no, pc, labels)
    if mnemonic in JUMP_MNEMONICS:
        return jump_instruction(tokens, opcode, line_no)
    if mnemonic in ALU_MNEMONICS:
        return alu_instruction(tokens, opcode, line_no, labels)

    raise ValueError(f"Unhandled mnemonic '{mnemonic}' on line {line_no}")


def assemble_file(src_path, base):
    with open(src_path, "r") as f:
        lines = f.readlines()

    labels, instruction_lines = first_pass(lines)

    # Labels resolve to absolute word addresses (base + index), so they
    # can be used directly as immediate jump targets; branch displacements
    # subtract the instruction's own absolute address.
    abs_labels = {name: idx + base for name, idx in labels.items()}

    machine_code = []
    for idx, (line_no, text) in enumerate(instruction_lines):
        instr = assemble_instruction(line_no, text, idx + base, abs_labels)
        if instr is not None:
            machine_code.append(instr)

    return labels, machine_code


# ---------------------------------------------------------------------------
# Output writers - fixed literal names in the current working directory,
# never derived from the input path.
# ---------------------------------------------------------------------------

def write_outputs(base, code):
    bin_text = "\n".join(f"{instr:032b}" for instr in code) + "\n"
    hex_text = "\n".join(f"{instr:08x}" for instr in code) + "\n"

    h_text_lines = [
        "// Auto-generated by Assembler.py from trading.asm. Do not edit.",
        "#ifndef FPGA_PROGRAM_H",
        "#define FPGA_PROGRAM_H",
        "",
        f"#define FPGA_PROGRAM_BASE {base}u",
        f"#define FPGA_PROGRAM_LEN  {len(code)}u",
        "",
        "static const unsigned int fpga_program[FPGA_PROGRAM_LEN] = {",
    ]
    for i, instr in enumerate(code):
        comma = "," if i + 1 < len(code) else ""
        h_text_lines.append(f"    0x{instr:08X}u{comma}   // word {base + i}")
    h_text_lines += ["};", "", "#endif", ""]
    h_text = "\n".join(h_text_lines)

    Path("fpga_program.bin").write_text(bin_text, encoding="ascii")
    Path("fpga_program.hex").write_text(hex_text, encoding="ascii")
    Path("fpga_program.h").write_text(h_text, encoding="ascii")


def main():
    parser = argparse.ArgumentParser(description="FMMA CPU assembler")
    parser.add_argument("filename", help="assembly source, e.g. trading.asm")
    parser.add_argument("--base", type=int, default=8,
                        help="word address the program is loaded at "
                             "(default 8)")
    args = parser.parse_args()

    try:
        src = resolve_source_path(args.filename)
    except ValueError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    labels, code = assemble_file(src, args.base)

    print("Labels (absolute word addresses):")
    for name, idx in labels.items():
        print(f"  {name}: {args.base + idx}")

    print("\nListing:")
    for i, instr in enumerate(code):
        print(f"  {args.base + i:4d}: 0x{instr:08X}  {instr:032b}")

    if any(w == 0 for w in code):
        print("\nERROR: program contains a 32'b0 word - that opcode "
              "parks the CPU in its halt state!")
        sys.exit(1)

    write_outputs(args.base, code)
    print(f"\nWrote fpga_program.bin / .hex / .h to the current directory "
          f"(base address {args.base}, {len(code)} words)")


if __name__ == "__main__":
    main()
