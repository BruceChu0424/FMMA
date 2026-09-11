# FMMA - HPS-side build
#
# Build natively on the DE1-SoC HPS Linux:
#     sudo apt-get install build-essential libssl-dev python3
#     make
#     sudo ./marketstream
#
# Cross compiling from a PC works too:
#     make CC=arm-linux-gnueabihf-gcc
#
# Targets:
#     make              build ./marketstream
#     make protocol     regenerate the shared memory map (C/asm/Verilog)
#     make program      re-assemble trading.asm -> fpga_program.*
#     make check        run the Python test suites
#     make check-generated  fail if a generated file is out of date
#     make clean
#
# ---------------------------------------------------------------------
# Two build settings are not optional, and both were learned the hard
# way (see docs/10-build-guide.md):
#
#  -std=gnu11, not -std=c11.  Strict ISO mode defines __STRICT_ANSI__,
#  which hides clock_gettime, CLOCK_MONOTONIC, usleep, mmap and
#  MAP_FAILED behind glibc's feature-test macros; the build fails with
#  a wall of implicit-declaration errors.
#
#  MG_TLS=MG_TLS_OPENSSL, not MG_TLS_BUILTIN.  Without any -DMG_TLS,
#  mongoose compiles with TLS disabled and every wss:// and https://
#  connection fails at the handshake - silently, because the program
#  turns mongoose logging down.  With the *builtin* stack it still
#  fails for Coinbase: mongoose's own code rejects P-384 certificate
#  intermediates ("reject secp386 for now"), and Coinbase is fronted by
#  Cloudflare, which uses one.  OpenSSL connects to both endpoints.
# ---------------------------------------------------------------------

CC       ?= gcc
CFLAGS   ?= -O2 -Wall -Wextra -Wno-unused-parameter -std=gnu11
CPPFLAGS += -DMG_TLS=MG_TLS_OPENSSL -DMG_ENABLE_PACKED_FS=0
LDLIBS   += -lssl -lcrypto -lrt -lm

PYTHON   ?= python3

TARGET    = marketstream
SOURCES   = MarketStream.c mongoose.c
GENERATED = fmma_protocol.h fmma_protocol.inc ../Testbenches/fmma_protocol.vh \
            fpga_program.h fpga_program.hex fpga_program.bin \
            fpga_program.mif fpga_program.lst
HEADERS   = mongoose.h fmma_protocol.h fpga_program.h

.PHONY: all protocol program check check-generated clean help

all: $(TARGET)

$(TARGET): $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $(SOURCES) $(LDLIBS)

# ---------------------------------------------------------------------
# Generated sources.  The memory map lives in protocol.py and is
# emitted into C, assembly and Verilog so the three cannot drift.
# ---------------------------------------------------------------------

protocol: fmma_protocol.h fmma_protocol.inc ../Testbenches/fmma_protocol.vh

fmma_protocol.h: protocol.py
	$(PYTHON) protocol.py --emit-c -o $@

fmma_protocol.inc: protocol.py
	$(PYTHON) protocol.py --emit-asm -o $@

../Testbenches/fmma_protocol.vh: protocol.py
	$(PYTHON) protocol.py --emit-vh -o $@

program: fpga_program.h

fpga_program.h: trading.asm fmma_protocol.inc Assembler.py fmma_isa.py
	$(PYTHON) Assembler.py trading.asm --quiet

../Testbenches/alu_vectors.txt: gen_alu_vectors.py fmma_sim.py fmma_isa.py
	$(PYTHON) gen_alu_vectors.py

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

check: program
	$(PYTHON) -m unittest discover -p 'test_*.py' -v

# Regenerate everything into a scratch directory and diff, so a
# hand-edited generated file cannot slip through review.
check-generated:
	@set -e; tmp=$$(mktemp -d); \
	$(PYTHON) protocol.py --emit-c   -o $$tmp/fmma_protocol.h; \
	$(PYTHON) protocol.py --emit-asm -o $$tmp/fmma_protocol.inc; \
	$(PYTHON) protocol.py --emit-vh  -o $$tmp/fmma_protocol.vh; \
	diff -u fmma_protocol.h   $$tmp/fmma_protocol.h; \
	diff -u fmma_protocol.inc $$tmp/fmma_protocol.inc; \
	diff -u ../Testbenches/fmma_protocol.vh $$tmp/fmma_protocol.vh; \
	$(PYTHON) Assembler.py trading.asm --quiet --outdir $$tmp; \
	diff -u fpga_program.hex $$tmp/fpga_program.hex; \
	rm -rf $$tmp; \
	echo "generated files are up to date"

clean:
	rm -f $(TARGET) *.o

help:
	@echo "make            build ./$(TARGET)"
	@echo "make protocol   regenerate the shared memory map"
	@echo "make program    re-assemble trading.asm"
	@echo "make check      run the Python test suites"
	@echo "make clean"
