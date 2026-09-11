#!/usr/bin/env python3
"""Unit tests for the FMMA assembler, ISA model and instruction set simulator.

Run with:
    python test_toolchain.py            (from the Software/ directory)
    python -m unittest test_toolchain   (same thing)

These tests are the first half of the verification story; the second half is
``Testbenches/`` , where the same programs run on the real RTL and the results
are compared against the simulator used here.  See docs/12-verification-plan.md.
"""

import unittest

import fmma_isa as isa
import fmma_sim as sim
from Assembler import AsmError, assemble_lines


def asm(*lines, base=8):
    """Assemble a few lines and return the machine words."""
    _symbols, code, _items = assemble_lines(list(lines), base)
    return code


def asm1(line, base=8):
    code = asm(line, base=base)
    assert len(code) == 1, f"expected 1 word, got {len(code)}"
    return code[0]


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------

class TestEncoding(unittest.TestCase):

    def test_rtype_field_layout(self):
        # 0000 | rd | op | rs
        self.assertEqual(asm1("XOR R1, R1"), 0x00000131)
        self.assertEqual(asm1("ADD R13, R7"), 0x00000D57)
        self.assertEqual(asm1("MOV R11, R9"), 0x00000BF9)
        self.assertEqual(asm1("SUB R11, R8"), 0x00000B98)
        self.assertEqual(asm1("CMP R4, R5"), 0x000004B5)
        self.assertEqual(asm1("MUL R2, R3"), 0x000002E3)

    def test_itype_field_layout(self):
        # imm[23:8] | op | rd | imm[7:0]
        self.assertEqual(asm1("OR R1, #64"), 0x00002140)
        self.assertEqual(asm1("OR R8, #100000"), 0x018628A0)
        self.assertEqual(asm1("AND R5, #0xFFFFFF"), 0xFFFF15FF)

    def test_load_store(self):
        self.assertEqual(asm1("LOAD R4, R1"), 0x00004401)
        self.assertEqual(asm1("STOR R13, R12"), 0x00004D4C)

    def test_branch_displacement_is_relative_to_the_branch(self):
        # BUC at index 1 (address 9) targeting the label at address 8 -> -1
        code = asm("HERE:", "NOP", "BUC HERE")
        self.assertEqual(code[1] & 0xFF, 0xFF)          # -1 as a byte
        self.assertEqual(isa.decode(code[1]).disp, -1)

    def test_forward_branch(self):
        code = asm("BEQ AWAY", "NOP", "NOP", "AWAY:", "NOP")
        self.assertEqual(isa.decode(code[0]).disp, 3)

    def test_jump_uses_an_absolute_register_target(self):
        self.assertEqual(asm1("JUC R15"), 0x00004ECF)

    def test_label_as_immediate_is_an_absolute_address(self):
        code = asm("OR R15, #LOOP", "LOOP:", "NOP", base=8)
        self.assertEqual(isa.decode(code[0]).imm, 9)

    def test_ldi_loads_the_immediate(self):
        code = asm("LDI R8, #100000")
        d = isa.decode(code[0])
        self.assertEqual((d.kind, d.op, d.rd, d.imm), ("itype", "MOV", 8, 100000))

    def test_nop_is_a_relative_branch_not_a_zero_word(self):
        word = asm1("NOP")
        self.assertNotEqual(word, 0)
        d = isa.decode(word)
        self.assertEqual((d.kind, d.disp), ("branch", 1))

    def test_equ_and_word(self):
        code = asm(".equ SIGNAL, 161", "OR R3, #SIGNAL", ".word 0xDEADBEEF")
        self.assertEqual(isa.decode(code[0]).imm, 161)
        self.assertEqual(code[1], 0xDEADBEEF)

    def test_comment_styles(self):
        self.assertEqual(asm1("OR R1, #64   % percent comment"), 0x00002140)
        self.assertEqual(asm1("OR R1, #64   ; semicolon comment"), 0x00002140)
        self.assertEqual(asm1("OR R1, #64   # hash comment"), 0x00002140)


# ---------------------------------------------------------------------------
# The guard rails: things the assembler must refuse
# ---------------------------------------------------------------------------

class TestRejections(unittest.TestCase):

    def test_every_alu_op_has_an_immediate_form(self):
        for op in sorted(isa.ALU_OPCODES):
            with self.subTest(op=op):
                asm(f"{op} R1, #5")

    def test_rejects_condition_codes_the_hardware_does_not_decode(self):
        for cc in ("GT", "CS", "CC", "HI", "LS", "LO", "HS", "FS", "FC"):
            with self.subTest(cc=cc):
                with self.assertRaises(AsmError):
                    asm(f"B{cc} 1")

    def test_accepts_every_implemented_condition(self):
        for cc in ("EQ", "NE", "LT", "GE", "LE", "UC"):
            with self.subTest(cc=cc):
                asm(f"B{cc} 1")
                asm(f"J{cc} R1")

    def test_never_emits_the_degenerate_condition_code(self):
        for cc in ("EQ", "NE", "LT", "GE", "LE", "UC"):
            word = asm1(f"B{cc} 1")
            self.assertNotEqual((word >> 8) & 0xF, isa.DEGENERATE_CONDITION_CODE,
                                f"B{cc} assembled to the always-taken code 1100")

    def test_rejects_a_zero_word_instruction(self):
        with self.assertRaises(AsmError):
            asm(".word 0")

    def test_rejects_out_of_range_branch(self):
        with self.assertRaises(AsmError):
            asm("BUC 200")

    def test_rejects_negative_immediate(self):
        with self.assertRaises(AsmError):
            asm("OR R1, #-1")

    def test_rejects_bad_registers_and_unknown_mnemonics(self):
        with self.assertRaises(AsmError):
            asm("ADD R16, R1")
        with self.assertRaises(AsmError):
            asm("FROB R1, R2")
        with self.assertRaises(AsmError):
            asm("LOAD R1")

    def test_rejects_duplicate_labels(self):
        with self.assertRaises(AsmError):
            asm("A:", "NOP", "A:", "NOP")


# ---------------------------------------------------------------------------
# Round trip: encode -> decode
# ---------------------------------------------------------------------------

class TestRoundTrip(unittest.TestCase):

    def test_all_rtype_combinations(self):
        for op in isa.ALU_OPCODES:
            for rd in (0, 1, 7, 15):
                for rs in (0, 3, 15):
                    word = isa.encode_rtype(op, rd, rs)
                    d = isa.decode(word)
                    self.assertEqual((d.kind, d.op, d.rd, d.rs),
                                     ("rtype", op, rd, rs))

    def test_all_itype_combinations(self):
        for op in sorted(isa.ALU_OPCODES):
            for imm in (1, 0xFF, 0x100, 100000, 0xFFFFFF):
                word = isa.encode_itype(op, 5, imm)
                d = isa.decode(word)
                self.assertEqual((d.kind, d.op, d.rd, d.imm),
                                 ("itype", op, 5, imm))

    def test_all_displacements(self):
        for disp in range(isa.DISP_MIN, isa.DISP_MAX + 1):
            d = isa.decode(isa.encode_branch("UC", disp))
            self.assertEqual(d.disp, disp)

    def test_load_store_roundtrip(self):
        for rd in range(16):
            for ra in range(16):
                if (rd, ra) != (0, 0):        # LOAD R0,R0 is the zero word
                    d = isa.decode(isa.encode_load(rd, ra))
                    self.assertEqual((d.kind, d.rd, d.ra), ("load", rd, ra))
                d = isa.decode(isa.encode_stor(rd, ra))
                self.assertEqual((d.kind, d.rs, d.ra), ("stor", rd, ra))

    def test_zero_word_decodes_as_halt(self):
        self.assertEqual(isa.decode(0).kind, "halt")


# ---------------------------------------------------------------------------
# ALU semantics (the model must match Code/ALUFinal)
# ---------------------------------------------------------------------------

class TestAlu(unittest.TestCase):

    def test_add_and_sub(self):
        self.assertEqual(sim.alu("ADD", 5, 7)[0], 12)
        self.assertEqual(sim.alu("SUB", 7, 5)[0], 2)
        self.assertEqual(sim.alu("SUB", 5, 7)[0], 0xFFFFFFFE)

    def test_add_wraps_at_32_bits(self):
        self.assertEqual(sim.alu("ADD", 0xFFFFFFFF, 1)[0], 0)

    def test_addu_sets_carry_add_does_not(self):
        self.assertEqual(sim.alu("ADDU", 0xFFFFFFFF, 1)[1].c, 1)
        self.assertEqual(sim.alu("ADD", 0xFFFFFFFF, 1)[1].c, 0)

    def test_mov_returns_the_b_input(self):
        self.assertEqual(sim.alu("MOV", 111, 222)[0], 222)

    def test_logical_ops_clear_the_flags(self):
        # ALUFinal never assigns Flags in the AND/OR/XOR arms, and the control
        # FSM asserts Fen for the whole R/I class, so these wipe the flags.
        for op in ("AND", "OR", "XOR", "MOV", "MUL"):
            self.assertEqual(sim.alu(op, 0, 0)[1].as_int(), 0)

    def test_cmp_zero_flag(self):
        self.assertEqual(sim.alu("CMP", 42, 42)[1].z, 1)
        self.assertEqual(sim.alu("CMP", 42, 43)[1].z, 0)

    def test_cmp_signed_less_than(self):
        cases = [
            (1, 2, 1), (2, 1, 0), (2, 2, 0),                       # both positive
            (0xFFFFFFFF, 1, 1),                                    # -1 < 1
            (1, 0xFFFFFFFF, 0),                                    # 1 > -1
            (0xFFFFFFFE, 0xFFFFFFFF, 1),                           # -2 < -1
            (0x80000000, 0x7FFFFFFF, 1),                           # INT_MIN < INT_MAX
        ]
        for a, b, expect_n in cases:
            with self.subTest(a=a, b=b):
                self.assertEqual(sim.alu("CMP", a, b)[1].n, expect_n)

    def test_cmp_unsigned_less_than_including_mixed_signs(self):
        # The original ALUFinal got the mixed-sign case wrong; L must be a
        # plain unsigned comparison.
        self.assertEqual(sim.alu("CMP", 1, 0xFFFFFFFF)[1].l, 1)
        self.assertEqual(sim.alu("CMP", 0xFFFFFFFF, 1)[1].l, 0)

    def test_shift_left_and_right(self):
        self.assertEqual(sim.alu("LSH", 1, 4)[0], 16)
        self.assertEqual(sim.alu("LSH", 0xF0, 0x1C)[0], 0xF)       # -4 -> >> 4
        self.assertEqual(sim.alu("LSH", 0x80000000, 0x1F)[0], 0x40000000)  # -1 -> >>1
        self.assertEqual(sim.alu("LSH", 0xFF, 0)[0], 0xFF)         # 0 -> no shift

    def test_arithmetic_shift_preserves_the_sign(self):
        self.assertEqual(sim.alu("ASH", 0x80000000, 0x1F)[0], 0xC0000000)
        self.assertEqual(sim.alu("ASH", 0x40000000, 1)[0], 0x80000000)

    def test_legacy_shift_model_reproduces_the_old_bugs(self):
        # Kept so the fix can be demonstrated rather than asserted.
        self.assertEqual(sim.alu("LSH", 0xFF, 0, legacy_shifts=True)[0], 0x7F)
        self.assertNotEqual(sim.alu("LSH", 0xF0, 0x1C, legacy_shifts=True)[0], 0xF)


# ---------------------------------------------------------------------------
# Condition codes
# ---------------------------------------------------------------------------

class TestConditions(unittest.TestCase):

    def test_conditions_match_a_signed_comparison(self):
        values = (-3, -1, 0, 1, 2, 2 ** 31 - 1, -2 ** 31)
        expect = {
            "EQ": lambda x, y: x == y,
            "NE": lambda x, y: x != y,
            "LT": lambda x, y: x < y,
            "GE": lambda x, y: x >= y,
            "LE": lambda x, y: x <= y,
            "UC": lambda x, y: True,
        }
        for name, cond in isa.CONDITIONS.items():
            for x in values:
                for y in values:
                    _res, fl = sim.alu("CMP", x & 0xFFFFFFFF, y & 0xFFFFFFFF)
                    with self.subTest(cond=name, x=x, y=y):
                        self.assertEqual(cond.taken(fl.z, fl.n), expect[name](x, y))


# ---------------------------------------------------------------------------
# The simulator itself
# ---------------------------------------------------------------------------

class TestSimulator(unittest.TestCase):

    def run_prog(self, lines, base=8, instructions=200, mem=None):
        code = asm(*lines, base=base)
        cpu = sim.Cpu(pc=base)
        cpu.load_program(code, base)
        for addr, value in (mem or {}).items():
            cpu.write(addr, value)
        cpu.run(instructions, max_halt_polls=5)
        return cpu

    def test_ldi_then_arithmetic(self):
        cpu = self.run_prog(["LDI R1, #100", "LDI R2, #42", "SUB R1, R2",
                             "HALTLOOP:", "BUC HALTLOOP"], instructions=20)
        self.assertEqual(cpu.regs[1], 58)

    def test_mov_register_copies(self):
        cpu = self.run_prog(["LDI R1, #77", "MOV R2, R1", "L:", "BUC L"],
                            instructions=20)
        self.assertEqual(cpu.regs[2], 77)

    def test_immediate_operands_read_left_to_right(self):
        """OP Rd, #imm must compute Rd OP imm, not imm OP Rd.

        This is the defect the 2026 datapath fix addressed; before it,
        SUB computed imm - Rd, CMP compared the wrong way round and MOV
        with an immediate was a no-op.
        """
        cpu = self.run_prog(["LDI R1, #10", "SUB R1, #3", "L:", "BUC L"],
                            instructions=20)
        self.assertEqual(cpu.regs[1], 7, "SUB Rd,#k computed k - Rd")

        cpu = self.run_prog(["LDI R2, #100000", "L:", "BUC L"], instructions=20)
        self.assertEqual(cpu.regs[2], 100000, "MOV Rd,#k was a no-op")

        # CMP Rd,#k must set N when Rd < k.
        cpu = self.run_prog(["LDI R3, #5", "CMP R3, #7", "L:", "BUC L"],
                            instructions=20)
        self.assertEqual(cpu.flags.n, 1, "CMP Rd,#k compared the wrong way")
        cpu = self.run_prog(["LDI R3, #9", "CMP R3, #7", "L:", "BUC L"],
                            instructions=20)
        self.assertEqual(cpu.flags.n, 0)

        # LSH Rd,#k must shift Rd by k.
        cpu = self.run_prog(["LDI R4, #2", "LSH R4, #4", "L:", "BUC L"],
                            instructions=20)
        self.assertEqual(cpu.regs[4], 32, "LSH shifted the immediate")

    def test_ldi_is_a_single_word(self):
        self.assertEqual(len(asm("LDI R8, #100000")), 1)

    def test_load_and_store_through_a_register_address(self):
        cpu = self.run_prog(
            ["LDI R1, #200", "LDI R2, #201", "LOAD R3, R1", "STOR R3, R2",
             "L:", "BUC L"], instructions=20, mem={200: 0xABCD})
        self.assertEqual(cpu.read(201), 0xABCD)

    def test_backward_branch_loops(self):
        cpu = self.run_prog(["LDI R1, #0", "LDI R2, #1",
                             "TOP:", "ADD R1, R2", "CMP R1, R2", "BNE TOP",
                             "L:", "BUC L"], instructions=40)
        self.assertEqual(cpu.regs[1], 1)

    def test_jump_through_a_register(self):
        cpu = self.run_prog(["LDI R15, #TARGET", "JUC R15", "LDI R1, #99",
                             "TARGET:", "LDI R1, #7", "L:", "BUC L"],
                            instructions=20)
        self.assertEqual(cpu.regs[1], 7)

    def test_zero_word_parks_the_cpu(self):
        cpu = sim.Cpu(pc=8)                      # RAM is all zeros
        with self.assertRaises(sim.HaltForever):
            cpu.run(100, max_halt_polls=10)
        self.assertEqual(cpu.pc, 8)

    def test_cpu_starts_when_the_program_appears(self):
        cpu = sim.Cpu(pc=8)
        cpu.step()                                # one halt poll, PC unchanged
        self.assertEqual(cpu.halted_polls, 1)
        cpu.load_program(asm("LDI R1, #5", "L:", "BUC L"), 8)
        cpu.run(10, max_halt_polls=5)
        self.assertEqual(cpu.regs[1], 5)

    def test_instruction_timing_is_three_cycles(self):
        cpu = self.run_prog(["LDI R1, #1", "L:", "BUC L"], instructions=10)
        self.assertEqual(cpu.cycles, cpu.instructions * isa.CYCLES_PER_INSTRUCTION)

    def test_undefined_instruction_stalls_like_the_hardware(self):
        cpu = sim.Cpu(pc=8)
        cpu.write(8, 0x00004010)                  # 0100 form with instr[7:4]=0001
        with self.assertRaises(sim.HaltForever):
            cpu.step()


if __name__ == "__main__":
    unittest.main(verbosity=2)
