# DE1-SoC MarketStream Makefile

CC = arm-linux-gnueabihf-gcc

# Sysroot copied from the DE1-SoC
SYSROOT = $(HOME)/de1-sysroot

# Source files
SOURCES = MarketStream.c mongoose.c

# Output executable
TARGET = MarketStream

# Compiler flags
CFLAGS = --sysroot=$(SYSROOT) \
         -Wall \
         -O2 \
         -DMG_TLS=MG_TLS_OPENSSL

# Library search paths
LDFLAGS = --sysroot=$(SYSROOT) \
          -L$(SYSROOT)/lib \
          -L$(SYSROOT)/usr/lib

# Libraries
LDLIBS = -lssl -lcrypto -lpthread

.PHONY: all clean check

all: $(TARGET)

$(TARGET): $(SOURCES)
	$(CC) $(CFLAGS) $(SOURCES) -o $(TARGET) $(LDFLAGS) $(LDLIBS)

check: $(TARGET)
	file $(TARGET)
	$(CC) --version
	arm-linux-gnueabihf-readelf -V $(TARGET) | grep GLIBC_ | tail

clean:
	rm -f $(TARGET)
