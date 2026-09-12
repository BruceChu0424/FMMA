# 11. Board bring-up runbook

From a DE1-SoC in a box to a running demonstration.

Most of this is automated by `tools/deploy.py`, which exists so that a
bring-up is one command instead of twenty and so it is the same twenty
every time. The manual steps are written out as well, because when
something goes wrong you need to know what the tool was doing.

> ## Read this before you touch anything
>
> **On Cyclone V there is no timeout on the HPS-to-FPGA bridge.**
>
> If the FPGA is not configured — or is configured with a design that
> has nothing at the address you read — the AXI transaction never
> completes. The CPU core that issued it blocks forever, and in
> practice the whole board stops responding: no console, no shell, no
> recovery except pulling the power.
>
> This is not theoretical. It happened during this project's bring-up,
> from a single `./fmma-probe ramtest` after a configuration that had
> silently failed.
>
> Everything in this repository that touches the bridge checks
> `/sys/class/fpga/fpga0/status` first and refuses if it does not say
> `user mode`. Do not bypass that check with `--force` unless you know
> exactly what is in the fabric.

## 11.0 What you need

| Item | Notes |
|------|-------|
| Terasic DE1-SoC | Cyclone V `5CSEMA5F31C6` |
| microSD card | with a Cyclone V Linux image (Terasic or Cornell ECE5760) |
| USB micro-B cable | the **UART** port — this is the control channel |
| Ethernet cable | to a router with internet access |
| USB type-B cable | the blue **USB-Blaster** port — optional, see §11.5 |
| A development PC | with Python 3 and `pyserial`, and Quartus if you are rebuilding |
| An Alpaca **paper** account | for the API key pair |

Ethernet is not optional for the full demonstration: the feed and the
broker are both on the internet. It also makes file transfer about 500
times faster than the serial console.

```bash
python -m pip install pyserial
```

## 11.1 SD card

Use a prebuilt Cyclone V / DE1-SoC Linux image. Write it with
`balenaEtcher` or `dd`.

The MSEL switches also matter, and the factory default is **not** what
you want if you intend to program the FPGA from Linux — see §11.4.

> **Do not build a preloader from this repository's
> `hps_isw_handoff/`.** The HPS SDRAM parameters in the Qsys system are
> placeholders and describe the wrong memory device; a preloader built
> from them hangs before U-Boot with no console output.
> [05](05-fpga-design.md) §5.7 explains why, and why it does not affect
> anything else. Use the image's own preloader.

## 11.2 Serial console

Connect the micro-B **UART** cable. Windows enumerates a USB serial
port; find it in Device Manager (it is *not* one of the Bluetooth
ports).

```bash
python tools/boardctl.py --port COM5 info
```

That prints the kernel, the toolchain, the network state and whether an
FPGA manager is present. If you would rather drive it by hand: PuTTY,
serial, **115200** baud, 8-N-1, no flow control. Login is `root` with
no password on both common images.

Expect something like:

```
kernel       : Linux de1soclinux 3.13.0-00299-ga2e769f #4 SMP armv7l
gcc          : gcc (Ubuntu/Linaro 4.6.3-1ubuntu5) 4.6.3
openssl-dev  : not installed
fpga manager : fpga0
/dev/mem     : crw-r----- 1 root kmem 1, 1 /dev/mem
```

Two things in that output shape everything below: **gcc 4.6** has no
C11 mode (hence `-std=gnu99`), and **no OpenSSL headers** means the
application may have to be cross-compiled (§11.7).

## 11.3 Network

```bash
python tools/deploy.py net
```

which runs DHCP on `eth0` and checks connectivity. By hand:

```bash
ip link set eth0 up
dhclient -v eth0                      # or: udhcpc -i eth0
ip -4 addr show eth0
ping -c 2 8.8.8.8
ping -c 1 ws-feed.exchange.coinbase.com
```

If there is no DHCP server, set it manually:

```bash
ip addr add 192.168.1.50/24 dev eth0
ip route add default via 192.168.1.1 dev eth0
printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' >> /etc/resolv.conf
```

**This has to be redone after every reboot** unless you add it to the
image's startup. It is the most common reason the program appears to
hang with no data.

## 11.4 Program the FPGA

Two ways. The HPS route needs no extra hardware and is what
`deploy.py` uses.

### First: check MSEL

**The HPS can only configure the FPGA in a Fast Passive Parallel mode.**
The board's `SW10` DIP switch sets `MSEL[4:0]`, and a DE1-SoC ships
strapped for **Active Serial** (`MSEL = 10010`), where the FPGA loads
itself from the on-board EPCQ flash at power-up and the HPS is locked
out entirely.

In AS mode every attempt looks like this, for *any* bitstream including
the board's own:

```
altera_fpga_manager ff706000.fpgamgr: Invalid MSEL setting
altera_fpga_manager ff706000.fpgamgr: timeout
```

which is easy to misread as "my bitstream is bad". It is not; nothing
can be loaded this way until the straps change.

```bash
python tools/deploy.py fpga      # reads MSEL first and explains if it is wrong
```

To enable HPS configuration, set `SW10` to `MSEL = 01010` (FPPx16).
Switch 1 is MSEL0 and **ON = 0**:

| Switch | Signal | Want | Position |
|--------|--------|-----:|----------|
| SW10.1 | MSEL0 | 0 | **ON** |
| SW10.2 | MSEL1 | 1 | **OFF** |
| SW10.3 | MSEL2 | 0 | **ON** |
| SW10.4 | MSEL3 | 1 | **OFF** |
| SW10.5 | MSEL4 | 0 | **ON** |

From the factory default (`10010`) only switches 4 and 5 move. Then
power-cycle the board. Verify with `tools/msel.c`, which reads the
strap straight out of the FPGA manager's status register:

```bash
python tools/deploy.py status
```

If you would rather not touch the switches, use JTAG instead — it works
in any MSEL mode.

### From Linux, over the network (no JTAG needed)

```bash
python tools/deploy.py fpga
```

It transfers `output_files/HFTTop.rbf`, verifies the checksum, disables
the three bridges, writes the bitstream to `/dev/fpga0`, checks both
the FPGA manager status **and** the kernel log for a configuration
timeout, and only then re-enables the bridges. **If configuration
fails it puts the stock bitstream back** so the board stays usable.

By hand, the same sequence:

```bash
for b in fpga2hps hps2fpga lwhps2fpga; do
    echo 0 > /sys/class/fpga-bridge/$b/enable
done
dd if=/root/HFTTop.rbf of=/dev/fpga0 bs=1M
sleep 1
cat /sys/class/fpga/fpga0/status        # must say: user mode
dmesg | tail -5                         # must NOT say: fpgamgr timeout
for b in fpga2hps hps2fpga lwhps2fpga; do
    echo 1 > /sys/class/fpga-bridge/$b/enable
done
```

**If the status is not `user mode`, or dmesg shows a timeout, stop.**
Do not enable the bridges and do not run anything that touches
`0xFF200000`. Restore the stock bitstream:

```bash
python tools/deploy.py restore
```

Generate the `.rbf` from the `.sof` with:

```bash
quartus_cpf -c -o bitstream_compression=on \
    output_files/HFTTop.sof output_files/HFTTop.rbf
```

### Over JTAG

With the blue USB type-B cable and the USB-Blaster driver installed:

```bash
quartus_pgm -m jtag -o "p;output_files/HFTTop.sof"
```

This is the better route for a *new, unproven* bitstream, because the
programmer reports failure directly rather than leaving the fabric in a
half state.

### Confirm it visually

**`HEX0` should show a steady `8`.**

That single digit is the most useful check in this document, and it
needs no software at all. It is the low nibble of the CPU's program
counter, and 8 is the entry word — so the fabric is configured, the CPU
is out of reset, the shared RAM came up zeroed, and the CPU is parked
in its halt state waiting for a program. Exactly what
[07](07-shared-memory-protocol.md) §7.4 describes.

If it shows anything else, the design in the fabric is not this one.
Do not proceed. [15](15-troubleshooting.md) §15.1.

## 11.5 Check the link before trusting it

```bash
python tools/deploy.py push
python tools/deploy.py build probe      # just the diagnostic: 1 second
python tools/deploy.py probe ramtest
```

Expected:

```
RAM test on words 512..767 (the free region)
  PASS - 256 words, 32 data bits, no errors
  the window behaves as read/write RAM, so the FPGA is
  configured with a design that puts the shared memory here
```

This is the first thing that touches the bridge, which is why it comes
after the `HEX0` check and why it only writes to the free region above
the protocol block.

### If the bitstream transfer will not go through

`deploy.py fpga` sends the `.rbf` over HTTP from a short-lived server
on your PC, so the board has to be able to reach *you*. The usual
reason it fails is the Windows firewall blocking Python's listening
socket the first time, or the PC having several interfaces and the
tool advertising the wrong one. Check it from the board:

```bash
wget -O /dev/null http://<your-PC-IP>:<port>/...
```

You do not have to fix that to make progress. Put the `.rbf` on the
board any way you like — `scp`, a file-manager app, a USB stick — and
then point the tool at it:

```bash
python tools/deploy.py --port COM5 fpga --remote /home/root/HFTTop.rbf
```

**Where you put the file does not matter.** It is not picked up from a
directory by anything; the path is only an argument to `dd`. What
matters is the sequence, which is what this command still does for you:

```
MSEL = 01010 (FPPx16) - the HPS can configure the FPGA
disabling the bridges
writing the bitstream
FPGA manager reports: user mode
enabling the bridges
done: user mode
```

Doing that by hand is possible and is how boards get hung, because the
order is load-bearing:

```bash
for b in fpga2hps hps2fpga lwhps2fpga; do
    echo 0 > /sys/class/fpga-bridge/$b/enable
done
dd if=/home/root/HFTTop.rbf of=/dev/fpga0 bs=1M
cat /sys/class/fpga/fpga0/status          # must print: user mode
# ONLY if it said "user mode":
for b in fpga2hps hps2fpga lwhps2fpga; do
    echo 1 > /sys/class/fpga-bridge/$b/enable
done
```

Enabling the bridges after a configuration that did *not* reach user
mode is the specific mistake that hangs the board with no software
recovery. `--remote` also checks `dmesg` for an `fpgamgr: timeout` and
puts the stock bitstream back if anything went wrong, which the manual
sequence does not.

## 11.6 Measure the fabric before involving the network

Before any of TLS, DNS, the exchange or the broker is in the picture,
`fmma-bench` exercises the entire protocol against a synthetic quote
series and tells you whether the CPU is running and how fast:

```bash
python tools/deploy.py build bench
python tools/boardctl.py run "cd /root/fmma && ./fmma-bench --ticks 5000 --interval 300"
```

Expected — these are the figures measured on a working board:

```
info  fpga   CPU running: protocol v2, heartbeat 128311, position 0
info  bench  CPU idle loop rate: 1282155 loops/s (0.8 us per loop)

fabric decision latency, 5000 samples
  min        3 us
  mean       5 us
  p99       16 us
  max       17 us

ticks published   5000
decisions read    5000
unanswered        0
side mismatches   0
```

Two rows carry most of the value. **`unanswered 0`** means the CPU
answered every quote — the loop is running and the seqlock is working.
**`side mismatches 0`** means the assembly in the fabric and the C model
in `fmma_strategy.c` chose the same side on all 5 000 quotes, which is
hardware/software equivalence checked on silicon rather than in
simulation.

If `unanswered` equals the tick count, the CPU is not executing: check
`fmma-probe` for `FW_VERSION 0`, then §15.

## 11.7 Build the application

`marketstream` **cannot be built on the board.** The stock image ships
`libssl.so` without its headers, and its Ubuntu 12.04 archives have
been retired, so `libssl-dev` cannot be installed. This is confirmed,
not assumed.

```bash
tools/crossbuild.sh                   # static armhf; first run takes minutes
python tools/deploy.py pushbin        # copy the binaries over
```

The two diagnostics do build on the board, in about a second each,
because they depend on nothing but libc:

```bash
python tools/deploy.py build probe    # or: cd /root/fmma && make probe bench
```

See [10](10-build-guide.md) §10.4a for why the cross-build must be
static and which linker warnings are expected.

## 11.8 Credentials

Get a **paper trading** key pair from the Alpaca dashboard.

```bash
export APCA_API_KEY_ID='PK...'
export APCA_API_SECRET_KEY='...'
```

Never put these in a file inside the repository.
[18](18-security-and-compliance.md) explains why, including what to do
if you already have.

## 11.9 First run: no orders

```bash
sudo -E ./marketstream --dry-run --verbose --stats 10
```

`-E` matters: plain `sudo` strips the environment and the credentials
vanish.

Expected:

Actual output from a working board (threshold lowered to $2.00 so a
decision appears within seconds rather than minutes):

```
=== FMMA: BTC-USD -> FPGA -> paper trading (protocol v2) ===
[     0.000] info  config   product BTC-USD, symbol BTCUSD, qty 0.001
[     0.000] WARN  config   DRY RUN: no orders will be sent
[     0.000] info  tls      verifying certificates against /etc/ssl/certs/ca-certificates.crt
[     0.000] info  fpga     shared RAM mapped at 0xFF200000, 1024 words
[     0.000] info  fpga     disabling trading while the image is replaced
[     0.000] info  fpga     writing 154 program words at word 8, entry word last
[     0.000] info  fpga     program verified
[     0.000] info  fpga     waiting for the CPU
[     0.101] info  fpga     CPU running: protocol v2, heartbeat 128337, position 0
[     0.101] info  app      trading enabled in the fabric
[     0.852] info  feed     connected, subscribed to BTC-USD ticker
[     0.984] info  app      >>> FPGA SELL  (tick 10104, 5 us after the quote, fabric position 0)
[     0.984] info  exec     dry run: would send sell 0.001 BTCUSD
[     1.666] info  app      >>> FPGA SELL  (tick 10110, 5 us after the quote, fabric position 0)
[     1.666] info  exec     cooldown active, dropping sell
[     8.482] info  app      >>> FPGA BUY   (tick 10192, 32 us after the quote, fabric position 0)
[     8.482] info  exec     dry run: would send buy 0.001 BTCUSD
```

Checks, in order:

| Line | Proves |
|------|--------|
| `shared RAM mapped` | `/dev/mem` and the bridge window are fine |
| `program verified` | the readback matched — the bridge really is the shared RAM |
| `CPU running: protocol v2` | the fabric is executing, and the bitstream matches the program |
| `connected, subscribed` | TLS and the WebSocket work |
| `bid ... ask ...` | quotes are being parsed |
| `>>> FPGA BUY` | **the fabric made a decision.** This is the project working. |

`HEX0` should now be flickering rather than steady.

`cooldown active, dropping sell` is not an error: the strategy can
signal several times a second and `--cooldown` (1 s by default) keeps
the order rate inside the broker's limits. The fabric is not throttled —
only the execution path is.

## 11.10 Live paper trading

```bash
sudo -E ./marketstream --max-pos 3 --threshold 1000 --max-loss 5000 --stats 30
```

The order lines look like this — these four are illustrative, because
the runs recorded in [13](13-test-report.md) §13.5 were all `--dry-run`
pending a key rotation:

```
[    41.2] info  exec     sent buy 0.001 BTCUSD
[    41.3] info  exec     accepted (HTTP 200) id 9f3c... status accepted
[    41.8] info  exec     filled buy 1 @ 9743107 after 512 ms
[    41.8] info  risk     fill buy 1 @ 9743107 -> position 1, avg 9743107, realised 0
```

The statistics block is real, measured over 90 s on BTC-USD:

```
--- 30 s ---------------------------------------------
  ticks 142   signals 10   orders 0 sent / 0 filled / 0 rejected
  cooldown drops 5   missed signals 0   clamped prices 0   feed drops 0   errors 0
  quote -> decision seen:  min 5 us   mean 13 us   p99 31 us   max 31 us   (n=10)
  software strategy:       mean 1551 ns   max 8110 ns   (n=142)
```

**Expect a millisecond-scale `max` on a longer run** — 1082 µs is
typical. That is not the fabric. With the default `--poll-ms 1`, a
decision landing just after a poll waits most of a millisecond to be
noticed. Add `--poll-ms 0` and the mean drops from ~157 µs to ~12 µs.
[14](14-latency-and-performance.md) §14.5 has both columns.

Cross-check the position against the Alpaca dashboard; they should
agree. Ctrl-C stops cleanly and disables trading in the fabric.

## 11.11 Running the quoting strategy

```bash
cd Software && python Assembler.py market_maker.asm   # overwrites fpga_program.*
python ../tools/deploy.py push && python ../tools/deploy.py build
sudo -E ./marketstream --half-spread 200 --skew 50 --max-pos 5 --dry-run
```

`fmma-probe watch` then shows `QUOTE_BID`/`QUOTE_ASK` moving with the
mid and skewing as the position changes. [08](08-trading-strategy.md)
§8.6 describes the strategy.

## 11.12 Demonstrating the interesting parts

In order of how convincing they are:

1. **The CPU really is in the fabric.** `HEX0` steady at 8 before the
   loader runs, flickering after. Press `KEY[0]`: back to 8, and the
   host reports the CPU stopped.
2. **The decision comes from hardware.** The `>>> FPGA BUY` lines, each
   tagged with the latency from the quote that caused it.
3. **Risk is enforced in hardware, not software.** Run with
   `--max-pos 1`. After one buy, further buys are refused: `rejects`
   climbs while `position` stays at 1 — and that refusal is happening
   in the fabric, not in the C code. `fmma-probe watch` shows it live.
4. **The kill switch works.** From a second shell,
   `./fmma-probe write 263 0` sets `CFG_ENABLE = 0`; signals stop,
   `REJECTS` climbs, the heartbeat keeps running. `write 263 1`
   resumes.
5. **Hardware versus software.** `--bench` prints both timings.
   [14](14-latency-and-performance.md) has the honest interpretation.
6. **It is all tested.** `Testbenches/run_sim.sh` on the laptop: 96
   Python tests, 9,548 ALU vectors, 31 RTL assertions, 25 seconds.

## 11.13 Shutting down

Ctrl-C the application, then `poweroff`. Wait for the console to
confirm the filesystem is unmounted before cutting power.

## 11.14 Per-session checklist

```
[ ] power on; python tools/boardctl.py info
[ ] confirm MSEL = 01010 (SW10: 4 OFF, 5 ON) -- once, then never again
[ ] python tools/deploy.py net           -> board has an IP, ping works
[ ] python tools/deploy.py fpga          -> "user mode", no dmesg timeout
[ ] LOOK AT HEX0                         -> steady 8
[ ] python tools/deploy.py probe ramtest -> PASS
[ ] ./fmma-bench --ticks 5000            -> 0 unanswered, 0 side mismatches
[ ] export APCA_API_KEY_ID / APCA_API_SECRET_KEY
[ ] sudo -E ./marketstream --dry-run --stats 10
[ ] confirm "CPU running: protocol v2" and a ">>> FPGA" line
[ ] drop --dry-run
```

Only after a source change:

```
[ ] python tools/deploy.py push          -> sources
[ ] tools/crossbuild.sh                  -> marketstream (cannot build on the board)
[ ] python tools/deploy.py pushbin       -> binaries
```

## 11.15 If the board stops responding

Symptoms: the serial console is silent, Ctrl-C does nothing, ping may
or may not answer.

This is the bus hang described at the top. There is no software
recovery: **pull the power, wait five seconds, plug it back in.** The
SD card reloads the stock bitstream at boot, so the board comes back
in a known state.

Then work out which access did it before repeating it. In practice it
is always the same cause — the fabric was not configured with a design
that answers at `0xFF200000`. [15](15-troubleshooting.md) §15.2.
