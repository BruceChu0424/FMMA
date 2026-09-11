# FMMA - HPS-side build
#
#   make              build ./marketstream and ./fmma-probe
#   make probe        just the diagnostic (no TLS, no mongoose, builds in 1 s)
#   make test         run the host unit tests
#   make check        unit tests + the Python suites
#   make protocol     regenerate the shared memory map (C / asm / Verilog)
#   make program      re-assemble trading.asm -> fpga_program.*
#   make check-generated   fail if a generated file is stale
#   make static       a self-contained binary, for a board with no libssl-dev
#   make clean
#
# ---------------------------------------------------------------------
# Two settings are not optional, and both cost real time to discover.
#
#   -std=gnu99, not -std=c11 and not -std=gnu11.  The DE1-SoC images in
#   circulation carry gcc 4.6, which has no C11 mode at all; and strict
#   ISO mode (-std=c99) hides clock_gettime, usleep, mmap and MAP_FAILED
#   behind glibc's feature-test macros.  gnu99 is the intersection that
#   works on both the 2012-era image and a current toolchain.
#
#   MG_TLS=MG_TLS_OPENSSL, not the built-in stack.  With no -DMG_TLS at
#   all, mongoose compiles with TLS disabled and every wss:// and
#   https:// connection fails at the handshake - silently, because the
#   program turns mongoose's logging down.  With MG_TLS_BUILTIN it still
#   fails for Coinbase: mongoose rejects P-384 certificate
#   intermediates, and Coinbase is behind Cloudflare, which uses one.
# ---------------------------------------------------------------------

CC       ?= gcc
PYTHON   ?= python3

WARN      = -Wall -Wextra -Wno-unused-parameter
CFLAGS   ?= -O2 $(WARN) -std=gnu99
CPPFLAGS += -DMG_TLS=MG_TLS_OPENSSL -DMG_ENABLE_PACKED_FS=0
LDLIBS   += -lssl -lcrypto -lrt -lm

# mongoose is vendored third-party code; it does not get our warning flags
MONGOOSE_CFLAGS = -O2 -std=gnu99 -w

APP       = marketstream
PROBE     = fmma-probe
UNITTEST  = fmma-unittest

APP_SRC = src/main.c src/fmma_app.c src/fmma_config.c src/fmma_exec.c \
          src/fmma_feed.c src/fmma_fixed.c src/fmma_fpga.c src/fmma_json.c \
          src/fmma_log.c src/fmma_risk.c src/fmma_socfpga.c \
          src/fmma_stats.c src/fmma_strategy.c src/fmma_tls.c

TEST_SRC = tests/test_units.c src/fmma_fixed.c src/fmma_json.c \
           src/fmma_risk.c src/fmma_strategy.c src/fmma_log.c

GENERATED = fmma_protocol.h fmma_protocol.inc ../Testbenches/fmma_protocol.vh \
            fpga_program.h fpga_program.hex fpga_program.bin \
            fpga_program.mif fpga_program.lst

.PHONY: all probe test check check-generated protocol program static clean help

all: $(APP) $(PROBE)

# ---------------------------------------------------------------------
# The application
# ---------------------------------------------------------------------

$(APP): $(APP_SRC) mongoose.o fmma_protocol.h fpga_program.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -o $@ $(APP_SRC) mongoose.o $(LDLIBS)

mongoose.o: third_party/mongoose.c third_party/mongoose.h
	$(CC) $(MONGOOSE_CFLAGS) $(CPPFLAGS) -c -o $@ third_party/mongoose.c

# The probe deliberately has no dependencies beyond libc, so it still
# builds when TLS or the network stack is the thing that is broken.
probe: $(PROBE)
$(PROBE): src/fmma_probe.c fmma_protocol.h
	$(CC) $(CFLAGS) -o $@ src/fmma_probe.c

# ---------------------------------------------------------------------
# A self-contained binary, for a board with no libssl-dev.
#
# The DE1-SoC images in circulation ship libssl.so but not its headers,
# and their distributions are long past end of life, so apt cannot
# install them.  Building this on a machine that does have the headers
# and copying the result across is usually quicker than fixing that.
#
# Static glibc would normally break DNS, because getaddrinfo needs NSS
# plugins at run time.  It does not here: mongoose resolves names
# itself over UDP and never calls getaddrinfo.
# ---------------------------------------------------------------------

static: $(APP_SRC) third_party/mongoose.c fmma_protocol.h fpga_program.h
	$(CC) $(CFLAGS) $(CPPFLAGS) -static -o $(APP) \
	      $(APP_SRC) third_party/mongoose.c \
	      -lssl -lcrypto -lrt -lm -lpthread -ldl
	$(CC) $(CFLAGS) -static -o $(PROBE) src/fmma_probe.c

# ---------------------------------------------------------------------
# Generated sources.  The memory map lives in protocol.py and is emitted
# into C, assembly and Verilog so the three cannot drift apart.
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

# ---------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------

test: $(UNITTEST)
	./$(UNITTEST)

$(UNITTEST): $(TEST_SRC) fmma_protocol.h
	$(CC) $(CFLAGS) -o $@ $(TEST_SRC)

check: test program
	$(PYTHON) -m unittest discover -p 'test_*.py' -v

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
	rm -f $(APP) $(PROBE) $(UNITTEST) *.o

help:
	@sed -n '2,12p' Makefile | sed 's/^# \?//'
