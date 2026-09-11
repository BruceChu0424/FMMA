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
