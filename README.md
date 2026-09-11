# FMMA — FPGA Market Maker Accelerator

A low-latency market-making prototype on the DE1-SoC (Cyclone V SoC).
A custom 32-bit RISC CPU in the FPGA fabric makes trading decisions on
live market data, while the hard processor system (HPS, ARM Cortex-A9
running Linux) handles all networking: it streams prices from the
Coinbase WebSocket feed into a shared on-chip RAM over the lightweight
AXI bridge, and executes the CPU's trading signals as paper orders on
Alpaca.

**Status (Sep 2026):** the full chain is implemented and verified.
Simulation passes 8/8 (`Testbenches/tb_HFTTop.v`); the Quartus flow
completes end to end — synthesis, fitter, timing (worst setup slack
+2.55 ns at 50 MHz) and `output_files/HFTTop.sof` is generated
(1,652 ALMs = 5 % of the device). Remaining step: on-board demo.

```
Coinbase WS (BTC-USD)                           Alpaca paper trading
        │                                              ▲
        ▼                                              │ POST /v2/orders
┌─────────────────────── HPS / Linux ───────────────────┴────────┐
│  MarketStream.c (mongoose)                                     │
│   • parse match messages (price/size/side)                     │
│   • mmap 0xFF200000 -> write prices into shared RAM            │
│   • poll SIGNAL/HEARTBEAT words -> send orders                 │
└───────────────┬──────────────────────────────▲─────────────────┘
                │ LW AXI bridge (s1)           │
┌───────────────▼──────────────────────────────┴─────────────────┐
│            4 KB dual-port on-chip RAM (Qsys system)            │
└───────────────▲──────────────────────────────┬─────────────────┘
                │ s2 (fetch / load / store)    │
┌───────────────┴──────────────────────────────▼─────────────────┐
│  Custom 32-bit RISC CPU (ECE 3710 group 1011 design)           │
│   16 x 32-bit regs · 3-cycle FSM · runs trading.asm            │
│   self-starts when the HPS loader writes the program           │
└────────────────────────────────────────────────────────────────┘
```

## What is where

| Path | Contents |
|------|----------|
| `Software/HFTtop.v` | FPGA top level (referenced by the QSF; `Code/HFTtop.v` is a synced copy) |
| `Code/` | CPU modules (ALU, FSM, PC, IR, FR, reg bank, muxes, encoder, 7-seg decoder) |
| `Software/HPSfgpa2*/` | Platform Designer system: HPS + 4 KB dual-port on-chip RAM |
| `Software/trading.asm` | The market-making strategy for the CPU |
| `Software/Assembler.py` | Assembler for the CPU; emits `fpga_program.h/.hex/.bin` |
| `Software/MarketStream.c` | HPS program: loader + WebSocket feed + Alpaca execution |
| `Software/Makefile` | Native build on the board |
| `Testbenches/tb_HFTTop.v` | Full-chain self-checking testbench (+ `HPSfgpa2_stub.v`) |
| `Documents/PROTOCOL.md` | **The HPS ↔ FPGA shared-memory contract** |
| `Documents/BUILD-NOTES.md` | Quartus/WSL/Nios II build fixes on this machine |
| `Documents/` | ECE 3710 final report + original project topic |

## Shared memory protocol (summary)

Word indices in the 4 KB RAM; full contract in
[Documents/PROTOCOL.md](Documents/PROTOCOL.md):

| Word | Name | Direction | Meaning |
|------|------|-----------|---------|
| 0–7 | reserved | — | must stay zero |
| 8–63 | program | HPS→FPGA | CPU program, written once at startup |
| 64 | `BUY_PRICE` | HPS→FPGA | price × 10000 |
| 65 | `SELL_PRICE` | HPS→FPGA | price × 10000 |
| 66 | `SIGNAL` | FPGA→HPS | 1 = buy, 2 = sell (HPS clears after acting) |
| 67 | `HEARTBEAT` | FPGA→HPS | loop counter, proves the CPU is alive |
| 68 / 69 | `BUY_SIZE` / `SELL_SIZE` | HPS→FPGA | trade sizes |

Strategy (`trading.asm`): signal **buy** on a crossed market
(buy < sell) or when the price dips more than $10 below the previous
tick; signal **sell** when it spikes more than $10 above it.

## Requirements

**Hardware:** DE1-SoC board, microSD card with a Cyclone V Linux
image (the team used the Cornell ECE5760 image), Ethernet, USB-Blaster.

**Windows:** Quartus Prime 25.1 (project in `HFTTop.qpf`), Python 3
for the assembler, Icarus Verilog (optional, simulation) — see
`Documents/BUILD-NOTES.md` for the toolchain quirks on this machine.

**On the board (HPS Linux):** `build-essential`, network access
(DNS + default route).

## 1. HPS/Linux bring-up

1. Boot Linux from the microSD card.
2. Serial console (PuTTY): your COM port, 115200 baud.
3. Networking (once per boot):
   ```
   echo "nameserver 8.8.8.8" >> /etc/resolv.conf
   ip route add default via <router-ip> dev eth0
   ping -c 3 google.com
   ```
4. Copy the software over (`scp`/`pscp` or git).

## 2. Build the FPGA image

```
cd D:\Projects\OrCAD\FMMA
quartus_sh --flow compile HFTTop
```
Program `output_files/HFTTop.sof` via the Quartus Programmer.
HEX0 shows the low nibble of the CPU program counter — a steady
`8` means "waiting for a program" (normal after programming).

## 3. Build & run the HPS software

```
cd Software
python Assembler.py trading.asm      # regenerates fpga_program.h
make                                 # -> ./marketstream
export APCA_API_KEY_ID=...           # Alpaca paper keys (never commit them)
export APCA_API_SECRET_KEY=...
sudo ./marketstream
```

Expected console flow:

```
[LOADER] Writing 45 program words at word 8 ...
[LOADER] Program verified.
[LOADER] Waiting for the CPU heartbeat ...
[LOADER] CPU is running (heartbeat = 1).
Connected to Coinbase, subscribing to BTC-USD matches ...
[MARKET] $97432.10 x 0.0013 (sell) -> FPGA
[FPGA] heartbeat = 1234
>>> [FPGA] Signal: BUY (crossed or dipped market)      <- CPU decision
*** [EXECUTION] Sending buy order to Alpaca ***
[ALPACA] Response: HTTP/1.1 200 OK ...
```

Without `sudo` the program runs in simulation mode (no `/dev/mem`):
the Coinbase feed and Alpaca paths still work, FPGA I/O is skipped.

## 4. Simulation (no hardware needed)

```
cd Testbenches
iverilog -g2005 -o tb.vvp ../Software/HFTtop.v ../Code/PC.v ../Code/IR \
   ../Code/FR ../Code/registerFinal ../Code/MUX16to1 ../Code/MUX2to1 \
   ../Code/ALUFinal ../Code/FSMTrial ../Code/disp ../Code/Encoder4to16 \
   ../Code/decoder.v HPSfgpa2_stub.v tb_HFTTop.v
vvp tb.vvp
```

Checks: CPU waits at PC=8 while RAM is empty; starts when the
program is loaded; crossed market -> SIGNAL 1; quiet market -> no
signal; $105 dip -> SIGNAL 1; $155 spike -> SIGNAL 2.

## Troubleshooting

* **Readback mismatch at word 8** — wrong bridge base or the FPGA is
  not programmed. The design uses the **lightweight** bridge at
  `0xFF200000`; the old full-H2F address `0xC8000000` is wrong for
  this Qsys system.
* **No heartbeat** — the bitstream predates the memory map, or the
  RAM window maps to the wrong address. Rebuild and reprogram.
* **Orders skipped** — `APCA_API_KEY_ID`/`APCA_API_SECRET_KEY` not
  exported.
* **`make` on the board fails on `fpga_program.h`** — run the
  assembler first (see step 3).

## Known limitations / next steps

* The CPU polls shared RAM; a true interrupt/doorbell from the HPS
  would cut decision latency further (currently ~2 µs per loop at
  50 MHz).
* One signal word, one product (`BTC-USD`); the map has room for a
  small order book.
* The FPGA-side DDR3 PHY files come from a mirror because this
  machine's Quartus lacks the EMIF IP (details and the clean-up
  steps in `Documents/BUILD-NOTES.md`).
* Coinbase matches are taker-side prints, not real bid/ask — fine
  for the demo, not for real quotes.

## Credits

Custom CPU designed in ECE 3710 (group 1011: Henry Wilson, Bobby
Lofgren, Kaleb Neilson, Carson Ord). Continued as an ECE 4900 senior
project (Carlos Zavala, Kaleb Neilson, Zhenwei Zhu).
