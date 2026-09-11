# 10. Build guide

Three things get built, and they are independent:

| What | Where | How long | Needed when |
|------|-------|----------|-------------|
| The CPU program (`trading.asm` → `fpga_program.*`) | development PC | < 1 s | you changed the strategy or the memory map |
| The FPGA bitstream (`HFTTop.sof`) | development PC | ~1 h | you changed anything in `Code/`, `HFTtop.v`, the Qsys system, the QSF or the SDC |
| The host program (`marketstream`) | the board, or cross-compiled | ~30 s | you changed the host application or the memory map |

Most work touches only the first and the third. Rebuilding the bitstream is
rare, which is the point of putting the strategy in a loadable program.

## 10.1 Prerequisites

**Development PC (Windows in this project's case):**

| Tool | Version used | Purpose |
|------|--------------|---------|
| Quartus Prime Lite | 25.1std.0 at `D:\Software\quartus` | synthesis, fit, timing, programming |
| Python | 3.14 | assembler, memory map, simulator, tests |
| Icarus Verilog | 12.0 at `C:\iverilog` | simulation (`winget install Icarus.Verilog`) |
| Git Bash | any | running the shell scripts |

**On the board:**

```bash
sudo apt-get update
sudo apt-get install build-essential libssl-dev python3
```

`libssl-dev` is not optional; see §10.3. Be aware that the older
DE1-SoC images are Ubuntu 12.04-era and their archives are long gone,
so `apt-get` may not be able to fetch it. In that case build the
binary elsewhere - §10.4a.

## 10.2 Building the CPU program

```bash
cd Software
python protocol.py --emit-c   -o fmma_protocol.h
python protocol.py --emit-asm -o fmma_protocol.inc
python protocol.py --emit-vh  -o ../Testbenches/fmma_protocol.vh
python Assembler.py trading.asm
```

or just `make program` (which runs the same thing through the dependency
rules). Outputs, all in `Software/`:

| File | Used by |
|------|---------|
| `fpga_program.h` | the host application — the image the loader writes |
| `fpga_program.hex` | the Verilog testbenches, via `$readmemh` |
| `fpga_program.mif` | Quartus, if you ever want the program baked into the bitstream |
| `fpga_program.bin` | archive |
| `fpga_program.lst` | annotated listing: address, encoding, disassembly, source |

The assembler prints the symbol table and the listing, and fails rather than
emitting anything the hardware would misinterpret — see
[04](04-isa-reference.md) §4.7 for the list.

**The memory map is generated, not written.** If you change
`Software/protocol.py`, re-run all four commands above; `make check-generated`
fails the build if any generated file is stale.

## 10.3 Building the host program

There are three targets and they do not all build in the same place:

| Target | Needs | Builds on the board? |
|--------|-------|----------------------|
| `make probe` → `fmma-probe` | libc | yes, in about a second |
| `make bench` → `fmma-bench` | libc | yes, in about a second |
| `make` → `marketstream` | **OpenSSL headers** | **no** — see below |

```bash
cd Software
make probe bench          # on the board
sudo ./fmma-probe
```

**`marketstream` cannot be built on a stock DE1-SoC image.** The image
ships `libssl.so` but not `openssl/ssl.h`, and its Ubuntu 12.04
archives have been retired, so `apt-get install libssl-dev` cannot
succeed — this was confirmed on the board, not assumed. Cross-compile
it instead; §10.4a is one command.

That split is also why the two diagnostics deliberately avoid TLS: the
tools you need when the build is broken must not depend on the thing
that is broken.

Two compiler settings are not negotiable, and both cost real time to
discover:

**`-std=gnu99`, not `-std=c11` and not `-std=gnu11`.** Two separate
traps meet here. The DE1-SoC Linux images in circulation carry **gcc
4.6.3**, which has no C11 mode at all and rejects `-std=gnu11`
outright. And a *strict* ISO mode (`-std=c99`, `-std=c11`) defines
`__STRICT_ANSI__`, which hides `clock_gettime`, `CLOCK_MONOTONIC`,
`usleep`, `mmap` and `MAP_FAILED` behind glibc's feature-test macros,
producing a wall of implicit-declaration errors that look like a
missing header. `gnu99` is the intersection that works on both the
2012-era image and a current toolchain.

**`-DMG_TLS=MG_TLS_OPENSSL`, not the built-in stack.** With no `-DMG_TLS` at
all, mongoose compiles with TLS *disabled* and every `wss://` and `https://`
connection fails during the handshake — silently, because the program turns
mongoose's logging down. With `-DMG_TLS=MG_TLS_BUILTIN`, Alpaca works but
Coinbase does not: mongoose's built-in verifier contains

```c
} else if (issuer->pubkey.len == 96) {
  MG_ERROR(("reject secp386 for now"));
  return 0;
```

and Coinbase is fronted by Cloudflare, whose chain contains a P-384
intermediate. `.skip_verification` does not help, because the chain-signature
loop is not gated on it. OpenSSL connects to both endpoints. This was
confirmed by building each configuration and probing the live endpoints.

Cross-compiling from a PC works too, and on the older images it is the
only option; see §10.4a.

## 10.4 Building the FPGA bitstream

```bash
cd D:/Projects/OrCAD/FMMA
D:/Software/quartus/bin64/quartus_sh.exe --flow compile HFTTop
```

Roughly an hour, almost all of it in the fitter (the HPS hard IP dominates).
Output: `output_files/HFTTop.sof`.

Expected result: **0 errors**, and exactly two Critical Warnings, both about
HPS DDR3 pin placement (169085 and 174073). Those are explained in
[05](05-fpga-design.md) §5.7 and are not a functional problem — the pins are
placed by the hard IP. A third Critical Warning, 127003 about a missing
memory initialisation file, used to appear and should **not** any more; if
you see it, the on-chip RAM has picked up an initialisation path again and
the boot contract in [07](07-shared-memory-protocol.md) §7.4 is no longer
guaranteed.

To program the board:

```bash
D:/Software/quartus/bin64/quartus_pgm.exe -m jtag -o "p;output_files/HFTTop.sof"
```

or use the Quartus Programmer GUI. See [11](11-board-bringup.md) §11.4.

## 10.4a Cross-compiling a self-contained binary

This is the normal route for `marketstream`, not a fallback.

```bash
tools/crossbuild.sh                        # build all three, static armhf
python tools/deploy.py --port COM5 pushbin # copy them to the board
```

The first run builds a Docker image from
[`tools/Dockerfile.armhf`](../tools/Dockerfile.armhf) — Debian bookworm
with `crossbuild-essential-armhf` and `libssl-dev:armhf` — which takes a
few minutes. After that it is seconds.

**Static, not dynamic.** The cross toolchain has glibc 2.36 and the
board has 2.15, so a dynamically linked binary would not start: the
loader would ask for symbol versions the board has never heard of.
`make static` links OpenSSL and glibc in, and the board's distribution
stops mattering. The result should be:

```
marketstream: ELF 32-bit LSB executable, ARM, EABI5, statically linked,
              for GNU/Linux 3.2.0
```

The board runs kernel 3.13, comfortably above that floor.

Static glibc normally breaks name resolution, because `getaddrinfo`
loads NSS plugins at run time and a static binary has nowhere to load
them from. It does not break here: mongoose resolves DNS itself over
UDP and never calls `getaddrinfo`. The linker warns about this anyway —
along with `dlopen` and `gethostbyname`, reached from OpenSSL code that
mongoose does not use. Those three warnings are expected.

Use `bookworm`, not `bullseye`: bullseye is past end of life and its
security repository's `Release` file is expired, which fails
`apt-get update` inside the image.

## 10.5 Running the tests

```bash
Testbenches/run_sim.sh          # everything: Python + RTL, ~25 s
Testbenches/run_sim.sh --quick  # Python only, ~2 s
Testbenches/run_sim.bat         # same, from a Windows prompt
```

and the C unit tests, which need no board:

```bash
docker run --rm -v "$PWD:/work" -w /work/Software debian:bookworm-slim   bash -c 'apt-get update -qq && apt-get install -y -qq build-essential            && make test'
```

The script regenerates the memory map and the program first, so it also
catches a stale generated file. It exits non-zero on any failure.
[12](12-verification-plan.md) describes what each stage proves.

## 10.6 Machine-specific notes

These are peculiar to this project's development machine and are recorded so
the knowledge is not lost. [BUILD-NOTES.md](BUILD-NOTES.md) has the full
detail; the summary:

**Quartus Lite has no EMIF IP.** `qsys-generate` cannot regenerate the Qsys
system on this machine — it stops in `generate_hps_sdram.tcl`. Four generated
files were therefore taken from a public mirror of equivalent Qsys output and
are listed directly in the QSF. If you regenerate on a machine with the full
stack, **delete those four lines first** or you will get duplicate module
definitions.

**Two files had to be edited by hand for the same reason.** The on-chip RAM's
read-during-write mode and initialisation file are set in
`Software/HPSfgpa2.qsys` *and* in the generated
`Software/HPSfgpa2/synthesis/submodules/HPSfgpa2_onchip_memory2_0.v`. The
`.qsys` edit is what a future regeneration will honour; the generated-file
edit is what the current build actually compiles. Both are annotated in
place. If you regenerate, check that the regenerated file says
`read_during_write_mode_mixed_ports = "OLD_DATA"` and
`INIT_FILE = "UNUSED"`, and delete the hand edits.

**The Nios II command shell mis-detects WSL2.** Its `grep -q Microsoft
/proc/version` fails because WSL2 reports `microsoft-standard-WSL2` in
lowercase, which puts a non-existent toolchain directory on `PATH`. Fixed
with a case-insensitive grep and a native `.bat` replacement; see
BUILD-NOTES §1.

**No Questa licence.** Simulation is Icarus Verilog. The installed
`questa_fse` refuses to start without a licence file.

## 10.7 Clean rebuild from a fresh clone

```bash
git clone <repo> && cd FMMA

# 1. generated sources and the program
cd Software && make protocol && make program && cd ..

# 2. tests, before you trust anything
Testbenches/run_sim.sh

# 3. the bitstream (about an hour)
D:/Software/quartus/bin64/quartus_sh.exe --flow compile HFTTop

# 4. the host program — on the board
scp -r Software root@<board-ip>:/root/fmma
ssh root@<board-ip> 'cd /root/fmma && make'
```

Step 2 should print `all green`. If it does not, stop there; nothing after it
is meaningful.
