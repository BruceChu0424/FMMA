import sys
import re

# Simple opcode table


#// 0000 R to R
#parameter AND = 4'b0001; 
#parameter OR = 4'b0010; 
#parameter XOR = 4'b0011; 
#// 0100 L and S
#parameter ADD = 4'b0101;
#parameter ADDU = 4'b0110;
#parameter ADDC = 4'b0111;
##parameter LSH = 4'b1000;
#parameter SUB = 4'b1001;
#parameter SUBC = 4'b1010;
#parameter CMP = 4'b1011;
#// 1100 Branch
#parameter ASH = 4'b1101; // different from isa

#// ADDCU is not on the ISA	
#//parameter ADDCU = 4'b1001;
#parameter MUL = 4'b1110;
#parameter MOV = 4'b1111; //Different from isa
OPCODES = {
    
    "AND": 0x1,
    "OR": 0x2,
    "XOR": 0x3,
    "ADD": 0x5,
    "ADDU":  0x6,
    "ADDC":  0x7,
    "LSH": 0x8,
    "SUB": 0x9,
    "SUBC": 0xA,
    "CMP": 0xB,

    "LOAD": 0x40,
    "STOR": 0x44,
   
    "BEQ": 0xC0,
    "BGE": 0xCD,
    "BCS": 0xC2,
    "BCC": 0xC3,
    "BHI": 0xC4,
    "BLS": 0xC5,
    "BLO": 0xCA,
    "BHS": 0xCB,
    "BGT": 0xC6,
    "BLE": 0xC7,
    "BFS": 0xC8,
    "BFC": 0xC9,
    "BLT": 0xCC,
    "BUC": 0xCE,

    "JEQ": 0x40C,
    "JGE": 0x4DC,
    "JCS": 0x42C,
    "JCC": 0x43C,
    "JHI": 0x44C,
    "JLS": 0x45C,
    "JLO": 0x4AC,
    "JHS": 0x4BC,
    "JGT": 0x46C,
    "JLE": 0x47C,
    "JFS": 0x48C,
    "JFC": 0x49C,
    "JLT": 0x4CC,
    "JUC": 0x4EC,

    "ASH": 0xD,
    "MUL":  0xE,
    "MOV": 0xF,
}









# Regex for registers
REGISTER_PATTERN = re.compile(r"R(\d+)$", re.IGNORECASE)


#return decimal value
def parse_register(token):
    """
    Parse a register like 'R0'..'R15' and return its number as int.
    """
    #assign decimal value to register
    m = REGISTER_PATTERN.match(token)
    if not m:
        raise ValueError(f"Invalid register: {token}")
    n = int(m.group(1))
    if not (0 <= n <= 15):
        raise ValueError(f"Register out of range (0-15): R{n}")
    return n

def strip_comment(line):
    """
    Remove everything after '%'
    """
    #split line at %
    # return everything before % 
    return line.split("%", 1)[0].strip()


#input list of lines
# output tuple of non label instrcutions (line index, "instruction")
# output dictionary {"label", line index}
def first_pass(lines):
    """
    Find all labels
    Collect list of non-label instrcution
    """

    #dictionary of {label, line index}
    labels = {}

    #list of tuples for non label instruction
    #each tuple is formatted (index, instruction)
    instruction_lines = []
    pc = 0  # program counter = line index


    # lines = list of lines turned into strings
    # i = index of lines
    # raw = individual string in list
    for i, raw in enumerate(lines):

        # remove comment
        line = strip_comment(raw)

        # if line not empty continue
        if not line:
            continue

        # check if instruction
        if line.endswith(":"):

            # label = everything after :

            #remove last char
            label = line[:-1].strip()

            # check if starts with letter or _
            if not label.isidentifier():
                raise ValueError(f"Invalid label name on line {i+1}: {label}")
            
            # check if duplicate label
            if label in labels:
                raise ValueError(f"Duplicate label '{label}' on line {i+1}")
            
            # add label with its address to dictionary
            labels[label] = pc

           
        else:
            # if not label, add instruction to list
            # move to next line
            instruction_lines.append((i + 1, line))
            pc += 1

    return labels, instruction_lines



# turn jump instruction to machinbe code
# returns binary
def jump_instruction(tokens, opcode, line_no):
        if len(tokens) != 2:
            raise ValueError(f"ADD expects 1 operand on line {line_no}")
       
        rTarget  = parse_register(tokens[1])  

        lower16instrcution = ((opcode & 0xFFF) << 4) | (rTarget & 0xF)
        
        return lower16instrcution


# turn branch instruction to machine code
# returns binary
def branch_instruction(tokens, opcode, line_no):
        if len(tokens) != 2:
            raise ValueError(f"ADD expects 1 operand on line {line_no}")
       
        displacement  = parse_register(tokens[1])  

        instr = ((opcode & 0xFF) << 8) | (displacement & 0xFF)
       
        return instr


# turn laod instruction to machine code
# returns binary
def store_instruction(tokens, opcode, line_no):
        if len(tokens) != 3:
            raise ValueError(f"ADD expects 2 operands on line {line_no}")
        

        upper_op = ((opcode >> 4) & 0xF) 
        lower_op = (opcode & 0xF) 
        rd = parse_register(tokens[1])
        rs = parse_register(tokens[2])
        lower16instruction = ((upper_op << 12) | (rd << 8) | (lower_op << 4) | (rs))
        
        return lower16instruction


# turn laod instruction to machine code
# returns binary
def load_instruction(tokens, opcode, line_no):
        if len(tokens) != 3:
            raise ValueError(f"ADD expects 2 operands on line {line_no}")
        

        upper_op = ((opcode >> 4) & 0xF) 
        lower_op = (opcode & 0xF) 
        rd = parse_register(tokens[1])
        raddr = parse_register(tokens[2])
        lower16instruction = ((upper_op << 12) | (rd << 8) | (lower_op << 4) | (raddr))
        
        return lower16instruction

def alu_instruction(tokens, opcode, line_no):
    if len(tokens) != 3:
            raise ValueError(f"ALU expects 2 operands on line {line_no}")
    rd = parse_register(tokens[1])
    if(is_register(tokens[2])):
            rs = parse_register(tokens[2])
            instr16 = ((rd << 8) | (opcode << 4) | rs )
            instr32 = instr16 & 0xFFFF
    else: 
            imm = int(tokens[2], 0)      
            if not (0 <= imm <= 0xFFFFFF):
                raise ValueError("Immediate out of range …")
            imm &= 0xFFFFFF
            upper_imm = imm >>8
            lower_imm = imm & 0xFF
            instr32 = ((upper_imm << 16) | (opcode << 12) |
                       (rd << 8) | lower_imm)
            
    return instr32

def is_register(token):
    if token.upper().startswith("R"):
        return True
    else:
        return False


#inputs
def assemble_instruction(line_no, line, labels):
    """
    Convert a single line of assembly into a 16-bit integer.
    """
    # Split by whitespace and commas
    tokens = re.split(r"[,\s]+", line.strip())

    # remove empty strings
    tokens = [t for t in tokens if t]  

    #if empty string
    if not tokens:
        return None

    #find opcode
    mnemonic = tokens[0].upper() 

    #check unknown 
    if mnemonic not in OPCODES:
        raise ValueError(f"Unknown instruction '{mnemonic}' on line {line_no}")
    

    #find hex value for opcode
    opcode = OPCODES[mnemonic]

    # LOAD Rn, imm8
    if mnemonic == "LOAD":
        return load_instruction(tokens, opcode, line_no)

    # jump EQ Rtarget
    elif mnemonic == "JEQ": 
        return jump_instruction(tokens, opcode, line_no)
    
    # branch EQ 
    elif mnemonic == "BEQ": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch GE 
    elif mnemonic == "BGE": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch CS 
    elif mnemonic == "BCS": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch CC 
    elif mnemonic == "BCC": 
        return branch_instruction(tokens, opcode, line_no)
   
     # branch HI 
    elif mnemonic == "BHI": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch LS 
    elif mnemonic == "BLS": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch LO 
    elif mnemonic == "BLO": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch HS 
    elif mnemonic == "BHS": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch GT 
    elif mnemonic == "BGT": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch LE 
    elif mnemonic == "BLE": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch FS 
    elif mnemonic == "BFS": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch FC 
    elif mnemonic == "BFC": 
        return branch_instruction(tokens, opcode, line_no)
    
    
     # branch LT 
    elif mnemonic == "BLT": 
        return branch_instruction(tokens, opcode, line_no)
    
     # branch UC 
    elif mnemonic == "BUC": 
        return branch_instruction(tokens, opcode, line_no)
    

     # jump GE Rtarget
    elif mnemonic == "JGE": 
        return jump_instruction(tokens, opcode, line_no)
    
     # jump CS Rtarget
    elif mnemonic == "JCS": 
        return jump_instruction(tokens, opcode, line_no)
    
     # jump CC Rtarget
    elif mnemonic == "JCC": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump HI Rtarget
    elif mnemonic == "JHI": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump LS Rtarget
    elif mnemonic == "JLS": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump LO Rtarget
    elif mnemonic == "JLO": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump HS Rtarget
    elif mnemonic == "JHS": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump GT Rtarget
    elif mnemonic == "JGT": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump LE Rtarget
    elif mnemonic == "JLE": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump FS Rtarget
    elif mnemonic == "JFS": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump FC Rtarget
    elif mnemonic == "JFC": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump LT Rtarget
    elif mnemonic == "JLT": 
        return jump_instruction(tokens, opcode, line_no)
    
    # jump UC Rtarget
    elif mnemonic == "JUC": 
        return jump_instruction(tokens, opcode, line_no)

    
    # ADD 
    elif mnemonic == "ADD":
        return alu_instruction(tokens, opcode, line_no)

    # SUB 
    elif mnemonic == "SUB":
        return alu_instruction(tokens, opcode, line_no)
    
    # ADDU
    elif mnemonic == "ADDU":
        return alu_instruction(tokens, opcode, line_no)
    
    # ADDC 
    elif mnemonic == "ADDC":
        return alu_instruction(tokens, opcode, line_no)
    
    # MUL
    elif mnemonic == "MUL":
        return alu_instruction(tokens, opcode, line_no)
    
    # SUB
    elif mnemonic == "SUB":
        return alu_instruction(tokens, opcode, line_no)
    
    # CMP
    elif mnemonic == "CMP":
        return alu_instruction(tokens, opcode, line_no)
    
    # AND
    elif mnemonic == "AND":
        return alu_instruction(tokens, opcode, line_no)
    
    # OR 
    elif mnemonic == "OR":
        return alu_instruction(tokens, opcode, line_no)
    # XOF
    elif mnemonic == "XOR":
        return alu_instruction(tokens, opcode, line_no)
    # MOV
    elif mnemonic == "MOV":
        return alu_instruction(tokens, opcode, line_no)
    
    # ASH
    elif mnemonic == "ASH":
        return alu_instruction(tokens, opcode, line_no)
    # LSH 
    elif mnemonic == "LSH":
        return alu_instruction(tokens, opcode, line_no)
    
    # STOR
    elif mnemonic == "STOR":
        return store_instruction(tokens, opcode, line_no)







   
    else:
        raise ValueError(f"Unhandled mnemonic '{mnemonic}' on line {line_no}")


#return machine code and labels
def assemble_file(filename):

    #read lines
    with open(filename, "r") as f:
        lines = f.readlines()

    # Pass 1: find labels and instructions
    labels, instruction_lines = first_pass(lines)

    machine_code = []

    # Pass 2: encode instructions
    for pair in instruction_lines:
        line_no = pair[0]
        text = pair[1]
        instr = assemble_instruction(line_no, text, labels)
        if instr is not None:
            machine_code.append(instr)

    return labels, machine_code

def main():
    if len(sys.argv) != 2:
        print(f"Usage: python {sys.argv[0]} program.asm")
        return

    filename = sys.argv[1]
    labels, code = assemble_file(filename)

    print("Labels:")
    for name, addr in labels.items():
        print(f"  {name}: {addr}")

    print("\nMachine code as RAM init:")
    for i, instr in enumerate(code):
        print(f"ram[{i}] = 32'b{instr:032b};")

    # Optionally write to a file for Verilog `$readmemh`
    outname = filename + ".bin"
    with open(outname, "w") as f:
        for instr in code:
            f.write(f"{instr:032b}\n")
    print(f"\nWrote binary to {outname}")

if __name__ == "__main__":
    main()
