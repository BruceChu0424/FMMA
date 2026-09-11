# Contributing

Notes for anyone working on FMMA — which for now means the three of us and
whoever inherits it.

## The one rule

**Run the tests before you commit.**

```bash
Testbenches/run_sim.sh
```

25 seconds, and it catches the failure modes this project has actually had:
a memory map changed in one language but not the others, a strategy edit
that breaks the timing budget, an RTL change that makes the hardware diverge
from the simulator, and a generated file edited by hand.

If it does not print `all green`, do not commit.

## Where things live

```
Code/             the CPU's Verilog (mostly without .v extensions - inherited)
Software/         everything that runs on the host, plus the build tooling
  protocol.py       THE MEMORY MAP. Generates the C, asm and Verilog copies.
  fmma_isa.py       THE ISA. Generates the assembler and the simulator's behaviour.
  Assembler.py      parser and label resolver
  fmma_sim.py       golden-reference instruction set simulator
  trading.asm       the strategy
  MarketStream.c    the host program
  test_*.py         the Python test suites
Testbenches/      Verilog testbenches, the stub, and run_sim.sh
  legacy/           archived ECE 3710 testbenches, kept for provenance
docs/             the engineering record - see docs/README.md
output_files/     Quartus output; the .sof and the reports are committed
```

## Generated files: never edit these

| File | Generated from | By |
|------|----------------|-----|
| `Software/fmma_protocol.h` | `protocol.py` | `make protocol` |
| `Software/fmma_protocol.inc` | `protocol.py` | `make protocol` |
| `Testbenches/fmma_protocol.vh` | `protocol.py` | `make protocol` |
| `Software/fpga_program.{h,hex,bin,mif,lst}` | `trading.asm` | `make program` |
| `Testbenches/alu_vectors.txt` | `fmma_sim.py` | `gen_alu_vectors.py` |

They all carry a "do not edit" banner. `make check-generated` regenerates
into a temporary directory and diffs, so a hand edit fails the build rather
than surviving until it causes something strange.

Changing the memory map means editing `protocol.py` and re-running
`make protocol && make program`. All three languages then agree by
construction, which is the entire point.

## Making a change

### To the strategy

Edit `Software/trading.asm`, then:

```bash
cd Software && make program
python -m unittest test_strategy -v      # fast; covers the decision table
cd ../Testbenches && ./run_sim.sh        # confirm the RTL agrees
```

No bitstream rebuild. The program is loaded over the bridge at run time,
which is why iterating on strategy is seconds and iterating on hardware is
an hour.

Add a test for whatever behaviour you added. `test_strategy.py`'s `Board`
class drives the CPU exactly the way `MarketStream.c` does, so a test there
is a genuine protocol-level test, not a unit test of an internal.

### To the ISA or the CPU

This is the expensive path, and it has an ordering:

1. Change the RTL in `Code/`.
2. Change `Software/fmma_isa.py` to match, and `fmma_sim.py` if the
   behaviour changed.
3. `python gen_alu_vectors.py` and run `run_sim.sh` — `tb_alu` will tell you
   immediately whether the RTL and the model still agree.
4. Add a test that would have caught the bug you just fixed.
5. Rebuild the bitstream (about an hour) and re-run `run_sim.sh`.
6. **If the change alters what an existing encoding means**, extend the
   datapath probe in `trading.asm` so an old bitstream cannot run a new
   program silently. See [docs/04-isa-reference.md](docs/04-isa-reference.md)
   §4.8 — this has already mattered once.

### To the protocol

1. Edit `Software/protocol.py`.
2. `make protocol && make program`.
3. Update both sides: `trading.asm` and `MarketStream.c`.
4. Update `Testbenches/tb_fmma.v` if the handshake changed.
5. Bump `PROTOCOL_VERSION` if the change is not backwards compatible. The
   `FW_VERSION` gate then refuses a mismatched pair instead of misbehaving.
6. Update [docs/07-shared-memory-protocol.md](docs/07-shared-memory-protocol.md).

### To the host program

```bash
# quickest check, no board and no root required
docker run --rm -v "$PWD:/work" -w /work/Software debian:bookworm-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq build-essential libssl-dev && make'
```

That is how it is checked on the Windows development machine, which has no
POSIX compiler. On the board, just `make`.

## Style

Match what is already there rather than introducing a second convention.

**Verilog.** The inherited CPU files use tabs and their original formatting;
leave that alone and match it locally. New files use four spaces. Comment
*why*, not *what* — several modules now carry a note explaining what was
wrong before, and those notes are the most valuable lines in the file.

**C.** C11 with POSIX (`-std=gnu11`), four spaces, `snake_case`. Builds
clean under `-Wall -Wextra`; keep it that way.

**Python.** Four spaces, `snake_case`, docstrings on anything non-obvious.
No third-party dependencies — the toolchain must work from a bare Python
install.

**Assembly.** Uppercase mnemonics, `%` comments, a comment on any line whose
purpose is not obvious from the mnemonic. Register allocation is documented
in the file header and there are only sixteen, so keep it current.

## Commits

Explain the *why*. `git log` is the only place some of this reasoning will
survive.

```
Fix the I-type operand order in the datapath

The immediate was muxed onto the ALU's A input, so every I-type
instruction computed "imm op Rd": SUB Rd,#k was k-Rd and MOV Rd,#k was a
no-op. Only commutative ops worked, which is why the old strategy loaded
constants with XOR/OR.

Moving the mux to the B input leaves the R-type encoding unchanged.
trading.asm now probes the wiring at startup and withholds FW_VERSION on a
mismatch, so a new program cannot run silently on an old bitstream.
```

Do not commit: credentials (see
[docs/18-security-and-compliance.md](docs/18-security-and-compliance.md)),
Quartus `db/` or `incremental_db/`, or a bitstream that does not correspond
to the committed sources.

Do commit the Quartus **reports** — `docs/13-test-report.md` quotes numbers
from them, and a reader has to be able to check the claim against the tool
output in the same revision.

## Adding documentation

`docs/` is numbered and indexed by `docs/README.md`. If you add a file, add
the row. If you change a measured number anywhere, change it in the document
that quotes it too — and say where the new number came from.
