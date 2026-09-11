# Tools

Host-side tooling. Neither of these is needed to build the project; they
exist so that working with the board is repeatable instead of a person
typing into a terminal emulator.

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

File transfer over the console is base64 at about 6 KB/s — fine for a
source file, painful for a 2 MB bitstream, which is why `deploy.py` uses
HTTP once the board has an address.

## `deploy.py` — bring-up, one step at a time

Automates [docs/11](../docs/11-board-bringup.md).

```bash
python tools/deploy.py status      # what state is the board in?
python tools/deploy.py net         # DHCP on eth0
python tools/deploy.py fpga        # program the FPGA, safely
python tools/deploy.py restore     # put the stock bitstream back
python tools/deploy.py push        # copy the software
python tools/deploy.py build
python tools/deploy.py probe ramtest
python tools/deploy.py run -- --dry-run
python tools/deploy.py all         # everything, in order
```

The serial console is the control channel; bulk data goes over HTTP from
a short-lived server on the development machine.

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
