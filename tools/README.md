# Tools

Host-side tooling. None of it is needed to build the FPGA bitstream;
it exists so that working with the board is repeatable instead of a
person typing into a terminal emulator — with one exception,
`crossbuild.sh`, which is the only way to build `marketstream` at all.

## `boardctl.py` — a scriptable serial console

The board's UART is the one link that always works: JTAG needs a
USB-Blaster and the network needs a route that a lab bench may not have.
This makes it programmable.

```bash
python tools/boardctl.py info                    # what is on the board
python tools/boardctl.py run "uname -a"
python tools/boardctl.py push Software/src/x.c /root/fmma/src/
python tools/boardctl.py pull /root/fmma/run.log logs/
python tools/boardctl.py shell                   # interactive
```

Every command is bracketed with a unique marker so the reply can be
separated from the echo and from kernel chatter. That is the whole trick
to making a serial console reliable: never parse a prompt, always parse a
marker you chose yourself.

The markers are built from shell variables, so the complete marker never
appears in what the console echoes back and the first literal occurrence
in the stream is guaranteed to be real output. And the whole thing goes
on **one line**, so the shell echoes all of it before running any of it.
Split across two lines it looks fine until a command's output does not
end in a newline — then the prompt and the echo of the epilogue land on
the same line as the last line of real output, and it cannot be
separated from them. That quietly swallowed the output of anything
ending without a newline: `ls | tr '\n' ' '` came back empty, and
`deploy.py status` reported `deployed : (nothing)` for a directory with
fifteen files in it.

File transfer over the console is base64 at about 6 KB/s — fine for a
source file, painful for a 2 MB bitstream, which is why `deploy.py` uses
HTTP once the board has an address.

## `deploy.py` — bring-up, one step at a time

Automates [docs/11](../docs/11-board-bringup.md).

```bash
python tools/deploy.py status      # what state is the board in?
python tools/deploy.py net         # DHCP on eth0
python tools/deploy.py fpga        # program the FPGA, safely
python tools/deploy.py fpga --remote /home/root/HFTTop.rbf   # already on the board
python tools/deploy.py restore     # put the stock bitstream back
python tools/deploy.py push        # copy the sources
python tools/deploy.py pushbin     # copy binaries from crossbuild.sh
python tools/deploy.py build
python tools/deploy.py probe ramtest
python tools/deploy.py run -- --dry-run
python tools/deploy.py all         # everything, in order
```

The serial console is the control channel; bulk data goes over HTTP from
a short-lived server on the development machine.

`push` sends the sources as one gzipped tarball — a file at a time meant
a serial round trip each, which for thirty-odd files was both slow and
fragile. A manifest travels inside the archive so the board can `touch`
exactly the files that arrived. That matters more than it sounds: `tar`
restores the *host's* modification times, the board's clock is rarely in
step, and sources that land looking older than the last build make
`make` quietly decide there is nothing to do. You then test the old
binary and cannot work out why your fix did nothing.

## `crossbuild.sh` — the only way to build `marketstream`

The board has `libssl.so` but not its headers, and its Ubuntu 12.04
archives are gone, so `libssl-dev` cannot be installed. `fmma-probe` and
`fmma-bench` build on the board in a second because they need nothing
but libc; `marketstream` cannot be built there at all.

```bash
tools/crossbuild.sh                        # static armhf, all three
python tools/deploy.py --port COM5 pushbin
```

The first run builds the image in [`Dockerfile.armhf`](Dockerfile.armhf)
— Debian bookworm plus `crossbuild-essential-armhf` and
`libssl-dev:armhf` — which takes a few minutes; after that it is
seconds. The output is **static**, because the cross toolchain has glibc
2.36 and the board has 2.15.

See [docs/10](../docs/10-build-guide.md) §10.4a for the details,
including why static glibc does not break DNS here and which linker
warnings are expected.

### Where files go on the board

| What | Where | Put there by |
|------|-------|--------------|
| Bitstream | `/root/fmma.rbf`, then written to `/dev/fpga0` | `fpga` |
| Sources | `/root/fmma/` | `push` |
| Binaries | `/root/fmma/` | `pushbin` |
| Logs you pull back | wherever you asked | `boardctl.py pull` |

The bitstream path is the one people expect to matter and it does not:
nothing reads the `.rbf` out of a directory, it is only an argument to
`dd if=... of=/dev/fpga0`. Drop it wherever you like and use
`fpga --remote <path>`. The sources and binaries do have to live
together in `/root/fmma`, because the Makefile and the runtime expect
`src/`, `fmma_protocol.h` and `fpga_program.h` beside each other.

### The safety rule

`fpga` never reports success on the FPGA manager's status alone. It also
checks the kernel log for a configuration timeout, and if anything looks
wrong it **puts the stock bitstream back** before returning.

That is not caution for its own sake. On Cyclone V there is no timeout on
the HPS-to-FPGA bridge: reading it when the fabric is unconfigured issues
an AXI transaction that never completes, and the board hangs hard enough
to need a power cycle. It is not recoverable in software, and it happened
during this project's bring-up.

## Requirements

```bash
python -m pip install pyserial
```

Nothing else. Both tools are plain Python 3 and talk to the board over a
serial port and, optionally, HTTP.
