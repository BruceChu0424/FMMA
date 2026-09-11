# FMMA - HPS-side build
#
# Build natively on the DE1-SoC HPS Linux (build-essential):
#   make                -> ./marketstream
#   make fpga_program.h -> regenerate the loader header from trading.asm
#                           (requires python3, run where you edit the .asm)
#
# Cross compiling from a PC is also possible, e.g.:
#   make CC=arm-linux-gnueabihf-gcc

CC      ?= gcc
CFLAGS  ?= -O2 -Wall -std=c11
LDLIBS   = -lm

TARGET   = marketstream
HEADERS  = mongoose.h fpga_program.h

all: $(TARGET)

$(TARGET): MarketStream.c mongoose.c $(HEADERS)
	$(CC) $(CFLAGS) -o $@ MarketStream.c mongoose.c $(LDLIBS)

# Assembler outputs land in the current directory (Software/)
fpga_program.h: trading.asm Assembler.py
	python Assembler.py trading.asm

clean:
	rm -f $(TARGET)

.PHONY: all clean
