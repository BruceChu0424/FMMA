# 11. Board bring-up runbook

From a DE1-SoC in a box to a running demonstration. Follow it in order; each
step has a check, and if a check fails, stop and go to
[15-troubleshooting](15-troubleshooting.md) rather than continuing.

Budget about 90 minutes the first time, 10 minutes thereafter.

## 11.0 What you need

| Item | Notes |
|------|-------|
| Terasic DE1-SoC | Cyclone V `5CSEMA5F31C6` |
| microSD card, ≥ 8 GB | with a Cyclone V Linux image (see §11.1) |
| USB cable, type A to B | the blue **USB Blaster** port, for JTAG |
| USB cable, micro-B | the **UART** port, for the serial console |
| Ethernet cable | to a router you control — see §11.3 |
| A development PC | with Quartus and the repository |
| An Alpaca **paper** account | for the API key pair |

The Ethernet requirement is the one that bites. University networks
generally block a device without a registered MAC, and the board needs
outbound TLS to two hosts. A home router, or a phone hotspot with a laptop
bridging, is the reliable option.

## 11.1 SD card

Use a prebuilt Cyclone V / DE1-SoC Linux image — the Terasic one from the
DE1-SoC CD, or the Cornell ECE5760 image the team used originally. Write it
with `balenaEtcher` or `dd`.

> **Do not build a preloader from this repository's `hps_isw_handoff/`.**
> The HPS SDRAM parameters in the Qsys system are placeholders and describe
> the wrong memory device; a preloader built from them hangs before U-Boot
> with no console output. [05](05-fpga-design.md) §5.7 explains why, and why
> it does not affect anything else. Use the image's own preloader.

Set the MSEL DIP switches for FPPx32 configuration from the HPS (the default
for these images; the DE1-SoC user manual has the table). Insert the card.

**Check:** the board powers up and the blue LEDs come on.

## 11.2 Serial console

Connect the micro-B **UART** cable. Windows enumerates a
`USB-to-Serial` COM port; find its number in Device Manager.

PuTTY → Serial, your COM port, **115200** baud, 8-N-1, no flow control.

Power-cycle the board and watch the boot log.

**Check:** you get a login prompt. On the Terasic and Cornell images the
user is `root` with no password.

```
socfpga login: root
root@socfpga:~#
```

## 11.3 Networking

The image does not come with usable DNS or a default route.

```bash
# DNS
cat >> /etc/resolv.conf <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# default route - use YOUR router's address
ip route add default via 192.168.1.1 dev eth0

# check
ip addr show eth0
ping -c 3 8.8.8.8
ping -c 3 ws-feed.exchange.coinbase.com
```

Find your gateway with `ipconfig` on a Windows machine on the same network
(the "Default Gateway" line) or `ip route` on Linux.

**This has to be redone after every reboot** unless you add it to the image's
startup. That is the single most common reason the program appears to hang
with no data: no route, so the TLS connect blocks.

**Check:** both pings succeed. If DNS fails but `8.8.8.8` works, the
`resolv.conf` edit did not take.

## 11.4 Program the FPGA

On the development PC, with the **USB Blaster** cable connected:

```bash
cd D:/Projects/OrCAD/FMMA
D:/Software/quartus/bin64/quartus_pgm.exe -m jtag -o "p;output_files/HFTTop.sof"
```

or Quartus → Tools → Programmer → Auto Detect → select the `5CSEMA5`
device → add `output_files/HFTTop.sof` → Start.

**Check: `HEX0` shows a steady `8`.**

That single digit tells you a lot. It is the low nibble of the CPU's program
counter, and 8 is the entry word — so the fabric is configured, the CPU is
out of reset, the on-chip RAM powered up zeroed, and the CPU is parked in its
halt state waiting for a program. Exactly what [07](07-shared-memory-protocol.md)
§7.4 describes.

If it shows something else, see [15](15-troubleshooting.md) §15.2.

## 11.5 Copy the software over

From the development PC:

```bash
cd D:/Projects/OrCAD/FMMA
scp -r Software root@<board-ip>:/root/fmma
```

`pscp` (from PuTTY) works the same way if you prefer. `git clone` on the
board is fine too, once §11.3 is done.

You only need `MarketStream.c`, `mongoose.c`, `mongoose.h`, `Makefile`,
`fmma_protocol.h` and `fpga_program.h`, but copying the directory is simpler
and lets you re-run the assembler on the board.

## 11.6 Build on the board

```bash
ssh root@<board-ip>          # or use the serial console
cd /root/fmma
apt-get update
apt-get install -y build-essential libssl-dev
make
```

**Check:** `./marketstream --help` prints the option list.

If the compile fails with implicit declarations, or the program later cannot
connect, re-read [10](10-build-guide.md) §10.3 — both failure modes come from
the two compiler settings.

## 11.7 Credentials

Get a **paper trading** key pair from
`https://app.alpaca.markets/paper/dashboard/overview` → API keys.

```bash
export APCA_API_KEY_ID='PK...'
export APCA_API_SECRET_KEY='...'
```

Never put these in a file inside the repository, and never commit them. See
[18](18-security-and-compliance.md), including what to do if you already
have.

## 11.8 First run: no orders

Start with everything safe:

```bash
sudo -E ./marketstream --dry-run --verbose --stats 10
```

`-E` matters: `sudo` strips the environment otherwise and the credentials
will not be visible.

Expected output:

```
=== FMMA: BTC-USD -> FPGA -> Alpaca (protocol v2) ===
Shared RAM mapped at 0xFF200000 (1024 words).
[LOADER] Disabling trading while the image is replaced.
[LOADER] Writing 154 program words at word 8 (entry word last).
[LOADER] Program verified.
[LOADER] Waiting for the CPU...
[LOADER] CPU running: protocol v2, heartbeat 41233, position 0.
Trading enabled: threshold 1000 cents, max position 5 lots.
[FEED] connected, subscribed to BTC-USD ticker
[MARKET] bid 97431.02  ask 97431.98
[MARKET] bid 97430.55  ask 97431.44
>>> [FPGA] BUY  (tick 34, 812 us after the quote was published, position 0)
[EXEC] dry run: would send buy 0.001 BTCUSD
```

**Checks, in order:**

| Line | Means |
|------|-------|
| `Shared RAM mapped` | `/dev/mem` and the bridge window are fine |
| `Program verified` | the readback matched — the bridge really is talking to the RAM |
| `CPU running: protocol v2` | the fabric is executing, and the bitstream matches the program |
| `[FEED] connected` | TLS and the WebSocket work — this is the step that fails without OpenSSL |
| `[MARKET]` lines | quotes are being parsed |
| `>>> [FPGA]` | **the fabric made a decision.** This is the whole project working. |

`HEX0` should now be flickering rather than steady: the CPU is running.

## 11.9 Live paper trading

Once the dry run looks right:

```bash
sudo -E ./marketstream --max-pos 3 --threshold 1000 --stats 30
```

Watch for:

```
*** [EXEC] buy 0.001 BTCUSD ***
[ALPACA] accepted (HTTP 201, 84 ms)

--- 30 s: 142 ticks, 3 signals, 3 orders, 0 rejected, 0 errors ---
    quote -> decision seen: min 786 us, mean 941 us, max 1203 us
    FPGA: heartbeat 38472911, position 1, rejects 0, status 0x1
```

Cross-check the position against the Alpaca dashboard. They should agree.

To stop: Ctrl-C. The program disables trading on the FPGA, prints final
statistics and unmaps cleanly.

## 11.10 Demonstrating the interesting parts

For a review or a demo, these are the things worth showing, in order:

1. **The CPU is really in the fabric.** `HEX0` steady at 8 before the loader
   runs, flickering after. Press `KEY[0]`: it goes back to 8 and the host
   reports the CPU stopped.
2. **The decision comes from hardware.** `>>> [FPGA] BUY` lines, with the
   latency figure attached to the quote that caused them.
3. **Risk is enforced in hardware, not software.** Run with `--max-pos 1`.
   After one buy, further buys are refused and `rejects` climbs while
   `position` stays at 1 — and that refusal is happening in the fabric, not
   in the C code.
4. **The kill switch works.** From a second shell, write zero to
   `CFG_ENABLE` — word 263, so byte offset 263 × 4 = 0x41C, address
   `0xFF20041C`:
   ```
   devmem2 0xFF20041C w 0     # signals stop
   devmem2 0xFF20041C w 1     # and resume
   ```
   While it is zero the heartbeat keeps running and `REJECTS` climbs, so you
   can see the strategy still working and still being refused.
5. **Hardware versus software.** `--bench` prints the software strategy's
   timing next to the fabric's. [14](14-latency-and-performance.md) has the
   interpretation — and the honest caveat.
6. **It is all tested.** `Testbenches/run_sim.sh` on the laptop, 31 RTL
   assertions and 82 Python tests, in 25 seconds.

## 11.11 Shutting down

```bash
# Ctrl-C the program, then
poweroff
```

Wait for the console to say the filesystem is unmounted before cutting power,
or the SD card image will eventually be corrupted.

## 11.12 Per-session checklist

Once everything is set up, a fresh session is:

```
[ ] power on, serial console at 115200
[ ] ip route add default via <gateway> dev eth0
[ ] ping -c 2 8.8.8.8
[ ] program HFTTop.sof over JTAG        -> HEX0 shows 8
[ ] export APCA_API_KEY_ID / APCA_API_SECRET_KEY
[ ] sudo -E ./marketstream --dry-run --stats 10
[ ] confirm "CPU running: protocol v2" and a ">>> [FPGA]" line
[ ] drop --dry-run
```
