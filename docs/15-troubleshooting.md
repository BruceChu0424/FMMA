# 15. Troubleshooting

Symptom → cause → fix. Start with §15.1, which resolves most of it in thirty
seconds.

> ## The board has stopped responding entirely
>
> No console output, Ctrl-C does nothing, ping may or may not answer.
>
> **Cause:** something read the HPS-to-FPGA bridge while the fabric was
> not configured with a design that answers at that address. Cyclone V
> has no bus timeout, so the AXI transaction never completes and the
> core that issued it is stuck forever.
>
> **Fix:** pull the power, wait five seconds, plug it back in. There is
> no software recovery. The SD card reloads the stock bitstream at boot,
> so the board comes back in a known state.
>
> **Prevention:** never touch `0xFF200000` unless
> `/sys/class/fpga/fpga0/status` says `user mode` *and* `dmesg` shows no
> `fpgamgr timeout` since the last configuration. `tools/deploy.py` and
> every program in `Software/src` check this; `--force` bypasses it and
> should not be used casually.

## 15.1 First, look at HEX0

The seven-segment digit shows the low nibble of the CPU's program counter,
and it answers the first question — is the fabric alive? — without any
software at all.

| HEX0 | Meaning | Next |
|------|---------|------|
| steady `8` | The CPU is parked at the entry word waiting for a program. **Normal** after configuration and before the loader runs. | Run `marketstream`. |
| flickering | The CPU is running. | The fabric is fine; the problem is on the host or the network. |
| blank / all segments | The FPGA is not configured, or there is no power. | §15.2 |
| steady, not `8` | The CPU has parked on a zero word somewhere else, or is stuck in the `ISA_MISMATCH` loop. | §15.4 |

## 15.2 The FPGA will not configure

### `Invalid MSEL setting` followed by `fpgamgr: timeout`

This is the one that wastes an afternoon, because it looks like a bad
bitstream and is not.

`MSEL[4:0]` is strapped by `SW10` and decides how the FPGA is
configured. A DE1-SoC ships set to **Active Serial** (`10010`), where
the FPGA loads itself from the on-board EPCQ flash and the HPS cannot
configure it at all. In that mode *every* bitstream fails this way,
including the board's own `soc_system.rbf`.

Read the strap:

```bash
gcc -O2 -o msel tools/msel.c && ./msel        # on the board
python tools/deploy.py status                 # or from the PC
```

Fix: set `SW10` to `01010` (FPPx16) — from the default that is switches
4 OFF and 5 ON — and power-cycle. [11](11-board-bringup.md) §11.4 has
the table. Or use JTAG, which works in any mode.

### Everything else

| Symptom | Cause | Fix |
|---------|-------|-----|
| Programmer sees no device | Wrong USB port, or no driver | Use the **blue USB Blaster** port, not the UART one. Install the USB-Blaster II driver from `quartus/drivers`. |
| "Can't access JTAG chain" | Another Quartus or a stale `jtagd` holds it | Close the other Quartus; `jtagconfig --swap` or kill `jtagd`. |
| Programs, but HEX0 stays blank | MSEL switches set for a mode the image does not use | Check MSEL against the DE1-SoC manual for FPPx32-from-HPS. |
| Programs, then the board resets | Under-powered USB hub | Use the barrel power supply, not bus power. |

## 15.3 No serial console

| Symptom | Cause | Fix |
|---------|-------|-----|
| No COM port appears | Driver missing | Install the CP210x / FTDI driver; check Device Manager. |
| Garbage characters | Wrong baud rate | 115200, 8-N-1, no flow control. |
| Port opens, nothing at all | Wrong cable | The micro-B **UART** connector, not the USB Blaster type-B one. |
| Boot log then silence | The SD image is not booting | Re-write the card; check the MSEL switches. |

## 15.3a `status` says `FPGA : power off`

**That is the normal, healthy reading for a board that has not been
configured since boot.** It is not about the board's power, and it does
not mean anything is wrong.

`status` just prints `/sys/class/fpga/fpga0/status`, which is the FPGA
manager's mode field. `power off` is mode 0 — the fabric is
unconfigured. The board itself is obviously alive, because the same
command reported its IP, kernel and gcc version. Run `deploy.py fpga`
and it becomes `user mode`.

The states you will see, in the order they pass through:

| `status` | Meaning |
|----------|---------|
| `power off` | fabric unconfigured — expected before `deploy.py fpga` |
| `reset phase`, `configuration phase`, `initialisation phase` | mid-configuration |
| `user mode` | **configured and running** — the only state in which the bridge is safe to touch |

## 15.3b Transfers to the board fail (WSL, VPN, firewall)

Symptom: `push`, `pushbin` and `fpga` all time out, and `status`
prints `MSEL : could not read` — while the board is plainly reachable
and answering on the serial console.

They fail together because they share one mechanism. The board fetches
over HTTP from a short-lived server on your machine, so **the board has
to be able to open a connection to you.** Outbound working is not the
same thing, which is why the board pinging the internet tells you
nothing about this.

**Under WSL this cannot work as-is.** WSL2 puts Linux behind a NAT'd
virtual adapter, so the address `deploy.py` advertises is a `172.x`
one that exists only inside WSL, and the HTTP server binds inside the
WSL network namespace — so even passing the Windows LAN address will
not help without a port proxy. `deploy.py` detects this and says so.
Three ways out, easiest first:

1. **Run `deploy.py` from Windows Python**, not from WSL. Nothing else
   changes.
2. **For the bitstream, sidestep it entirely.** Copy the `.rbf` across
   however you like — `scp`, a file manager, a USB stick — then
   `deploy.py fpga --remote /home/root/HFTTop.rbf`. See §11.5.
3. **Forward the port from Windows** and name the address yourself:
   ```
   netsh interface portproxy add v4tov4 listenport=PORT \
         connectaddress=<WSL-IP> connectport=PORT
   deploy.py --host-ip <your-Windows-LAN-IP> push
   ```

Outside WSL the usual causes are the Windows firewall blocking
Python's first listening socket, or a VPN/Docker adapter winning the
route so the wrong address gets advertised. `--host-ip` fixes the
second; to confirm either, try the URL the tool prints from the board:

```bash
wget -O /dev/null http://<host>:<port>/
```

The MSEL check no longer depends on any of this — it pushes `msel.c`
over the serial console instead, because a safety check must not be
the thing that needs a healthy network.

## 15.4 The CPU does not start

`[LOADER] ERROR: no heartbeat.`

| Cause | How to tell | Fix |
|-------|-------------|-----|
| The FPGA is not configured | HEX0 blank | Program `output_files/HFTTop.sof`. |
| A previous program is wedged and not polling `CFG_RESTART` | HEX0 steady on something other than 8 | Press **`KEY[0]`**, then run the loader again. |
| The bitstream predates the program | See below | Rebuild and reprogram the bitstream. |

`[LOADER] ERROR: the CPU reports protocol vN but this program speaks vM.`

The bitstream and the program come from different revisions. This is the
`FW_VERSION` gate doing its job — see [04](04-isa-reference.md) §4.8.
Rebuild the bitstream (`quartus_sh --flow compile HFTTop`), reprogram, and
re-run. Do **not** work around it; the datapath probe failed for a reason,
and a program running on a mismatched datapath computes wrong numbers
silently.

A subtle variant: the heartbeat is moving but `FW_VERSION` stays 0. That is
the `ISA_MISMATCH` loop — the CPU is alive and deliberately refusing to
declare itself. Same fix.

### "Alive but will not declare a version" is not always the datapath

That message names the most likely cause, and during bring-up it named
the wrong one twice. Work through these before rebuilding anything:

| Cause | How to tell | Fix |
|-------|-------------|-----|
| The fabric is in a bad state from an earlier wedged program | Any program fails the same way, including one that worked minutes ago | `deploy.py fpga` — reconfiguring resets the CPU without anyone at the bench. `CFG_RESTART` cannot rescue a CPU that jumped into garbage. |
| The program publishes `FW_VERSION` once and then spins | It is a diagnostic or a one-shot, not one of the strategies | Honour `CFG_RESTART`, as below. |
| The datapath really is older than the program | `isa_probe` reports a specific failing bit | Rebuild and reprogram the bitstream. |

The second row is a trap worth spelling out. The loader writes the
entry word, which starts the CPU **immediately**, and only afterwards
zeroes `FW_VERSION` so a stale value cannot fool it. A short program
finishes in microseconds — long before that — so it publishes its
version, the loader wipes it, and nothing ever writes it again. The
loader then waits five seconds and blames the datapath.

The strategies survive this because `CFG_RESTART` sends them back
through `INIT`, where they re-publish. Any program the loader drives
must do the same; `isa_probe.asm` shows the minimum version.

### Which instruction is wrong: `isa_probe.asm`

The strategies' built-in datapath probe reports one bit — "something is
wrong" — and then spins. That is right for production and useless for
diagnosis.

```bash
cd Software && python Assembler.py isa_probe.asm     # becomes the image
cd .. && python tools/deploy.py --port COM5 push
python tools/boardctl.py --port COM5 run "cd /root/fmma && make bench && ./fmma-bench --ticks 1"
python tools/boardctl.py --port COM5 run "cd /root/fmma && ./fmma-probe read 328"
```

`1023` (`0x3FF`) means all ten checks passed. Anything else names the
broken instruction — the bit order is in the header of `isa_probe.asm`.
Word 329 is the number of checks and word 330 is the bit register,
which must end at 1024; if it does not, the mask cannot be read bit by
bit and the accumulator itself is suspect.

The same program runs in simulation as `tb_isa_probe`, part of
`run_sim.sh`. When the two disagree, the difference is the bug — which
is the whole point of having both.

Remember to re-assemble `trading.asm` afterwards, or the board keeps
running the probe.

## 15.5 Readback mismatch

```
[LOADER] ERROR: readback mismatch at word 8: wrote 0x..., read 0x...
```

The host is writing somewhere that is not the shared RAM.

| Cause | Fix |
|-------|-----|
| The FPGA is not configured, so the bridge has no slave | Program the `.sof` first. |
| Wrong bridge base address | It is `0xFF200000` (**lightweight** H2F). `0xC8000000` is the full-width H2F bridge, which this Qsys system does not use — an old note in the ECE 3710 archive says otherwise and is wrong for this design. |
| The bridge is not enabled in the device tree | Use the stock Terasic/Cornell image; it is enabled there. |
| Reading back zeros everywhere | Almost always "the FPGA is not configured". |

## 15.6 The build fails

### The host program

| Error | Cause | Fix |
|-------|-------|-----|
| `unrecognized command line option '-std=gnu11'` | the board's gcc is 4.6, which has no C11 mode | The Makefile uses `-std=gnu99`; check you have not overridden `CFLAGS`. |
| `CLOCK_MONOTONIC undeclared`, `implicit declaration of clock_gettime/usleep/mmap` | a strict `-std=c99`/`c11` hides POSIX behind `__STRICT_ANSI__` | Use `-std=gnu99`. |
| `openssl/ssl.h: No such file` | `libssl-dev` is missing, and on the older images the distribution is EOL so apt cannot fetch it | Cross-compile instead: [11](11-board-bringup.md) §11.7, `make static`. |
| `fpga_program.h: No such file` | The assembler has not been run | `make program`, or `python3 Assembler.py trading.asm` |
| `undefined reference to mg_tls_init` | mongoose built without TLS | Ensure `-DMG_TLS=MG_TLS_OPENSSL` reaches the compile. |

### The FPGA

| Error | Cause | Fix |
|-------|-------|-----|
| `Critical Warning 127003: Can't find Memory Initialization File` | The on-chip RAM has picked up an initialisation path again | The RAM must have **no** init file so it powers up zeroed; see [07](07-shared-memory-protocol.md) §7.4. Check `INIT_FILE` in `HPSfgpa2_onchip_memory2_0.v`. |
| Hundreds of errors about `SERIESTERMINATIONCONTROL` / dynamic termination | The HPS DDR3 pins have no I/O standard assignments | The `__hps_sdram_p0` block in the QSF supplies them; do not delete it. |
| `Can't resolve multiple constant drivers` / duplicate module | The four hand-supplied EMIF files collide with a regenerated QIP | Delete those four `set_global_assignment` lines from the QSF after regenerating. |
| `generate_hps_sdram.tcl` fails in `qsys-generate` | Quartus **Lite** has no EMIF IP | You cannot regenerate the Qsys system on this machine. See [10](10-build-guide.md) §10.6. |

### The tests

| Error | Cause | Fix |
|-------|-------|-----|
| `FATAL: cannot open alu_vectors.txt` | The vectors have not been generated | `python Software/gen_alu_vectors.py`, or just use `run_sim.sh`. |
| `fpga_program.hex looks empty` | The assembler has not been run | Same. |
| `iverilog: command not found` | Not on PATH | `winget install Icarus.Verilog`; `run_sim.sh` adds `C:\iverilog\bin` automatically. |
| A `check-generated` diff | A generated file was hand-edited, or `protocol.py` changed without regenerating | `make protocol && make program`. Never edit a generated file. |

## 15.7 No market data

| Symptom | Cause | Fix |
|---------|-------|-----|
| No `[FEED] connected` line ever | No route or no DNS | `ip route add default via <gateway> dev eth0`; check `/etc/resolv.conf`. This is the most common problem, and it comes back after every reboot. |
| `[FEED] error: ... certificate ...` | No CA bundle, or the built-in TLS stack | `apt-get install ca-certificates`; make sure the build used `MG_TLS_OPENSSL`. |
| Connects, then drops repeatedly | Flaky uplink | The program reconnects with backoff; check the network. |
| `WARNING: no CA bundle found` | No `ca-certificates` package | Install it, or pass `--ca /path/to/bundle`. |
| Connected but no `[MARKET]` lines | Wrong product id | `--product BTC-USD`. Check the console for a Coinbase error message. |

## 15.8 The engine runs but never trades

Work down this list; each row is a thing that is *supposed* to stop trades.

| Check | Command / where | Meaning |
|-------|-----------------|---------|
| Is the heartbeat moving? | statistics line | No → §15.4. |
| Are quotes arriving? | `--verbose` | No → §15.7. |
| Is `CFG_ENABLE` set? | `status 0x9` has bit 3 | Trading is disabled. The loader sets it; `--dry-run` does not clear it. |
| Is `REJECTS` climbing? | statistics line | The strategy wants to trade and the risk layer is refusing. Check `position` against `--max-pos`. |
| Is the threshold too high? | `--threshold` | $10 on BTC is a few trades an hour. Try 200 (= $2) to see activity. |
| Is the cooldown swallowing them? | `[EXEC] cooldown active` | Lower `--cooldown`. |
| Are credentials set? | `[EXEC] APCA_... not set` | `export` them and use `sudo -E`. |

That last one catches people constantly: plain `sudo` strips the
environment, so the keys vanish. Use `sudo -E`.

## 15.9 Orders are rejected

```
[ALPACA] REJECTED (HTTP 403): {"message":"insufficient buying power"}
```

| Status | Meaning | Fix |
|--------|---------|-----|
| 401 | Bad credentials | Check the key pair, and that they are **paper** keys for `paper-api.alpaca.markets`. |
| 403 | Insufficient buying power, or the asset is not tradable | Reset the paper account; check BTCUSD is enabled. |
| 422 | Bad order parameters | `--qty` below the minimum, or a bad symbol. |
| 429 | Rate limited | Raise `--cooldown`. |

## 15.10 The position is wrong

| Symptom | Cause | Fix |
|---------|-------|-----|
| The FPGA's `position` disagrees with Alpaca | A fill was reported that did not fill, or vice versa — see [09](09-risk-management.md) §9.6 | Restart with the true figure: `--position N`. |
| The position resets to 0 on restart | `CFG_POSITION` was not supplied | Pass `--position N`; the CPU adopts it deliberately rather than assuming zero. |
| The position never changes | Orders are being rejected | §15.9; only a 2xx reports a fill. |

## 15.11 Getting more detail

```bash
sudo -E ./marketstream --verbose --stats 5      # every quote, frequent stats
sudo -E ./marketstream --dry-run                # decisions without orders
./marketstream --no-fpga --bench                # no board, no root needed

# read any protocol word directly (word N is at 0xFF200000 + 4N)
devmem2 0xFF200500 w        # HEARTBEAT, word 320
devmem2 0xFF200510 w        # POSITION,  word 324
devmem2 0xFF200514 w        # STATUS,    word 325
devmem2 0xFF20041C w 0      # CFG_ENABLE = 0, word 263: stop trading now
```

And off the board:

```bash
Testbenches/run_sim.sh                                  # is the design still sane?
cd Software && python fmma_sim.py trading.asm --trace   # single-step the strategy
```
