# FMMA Shared Memory Protocol

This document defines the contract between the HPS (ARM Cortex-A9
running Linux) and the custom 32-bit RISC CPU in the FPGA fabric.
Both sides **must** agree on every item below.

## 1. Transport

| Item | Value |
|------|-------|
| Medium | 4 KB dual-port on-chip RAM (`onchip_memory2_0` in the Qsys system `HPSfgpa2`) |
| HPS port | `s1`, attached to the HPS lightweight AXI master |
| HPS Linux mapping | `mmap("/dev/mem", 0xFF200000, 4096)` |
| CPU port | `s2`, exported as `fpga_bram_s2`, word-addressed (1024 x 32 bit) |
| CPU fetch | word address = program counter (starts at 8) |
| CPU load/store | word address = `R[ra]` |

All indices below are **32-bit word indices**. The C program uses a
`volatile unsigned int *` into the mapped window, so `fpga_regs[N]`
is word `N` (byte offset `4*N`).

## 2. Memory map

| Words | Bytes (LW bridge) | Name | Direction | Contents |
|-------|-------------------|------|-----------|----------|
| 0 – 7 | 0x000 – 0x01F | reserved | — | must stay zero; a zero word parked at the PC halts the CPU |
| 8 – 63 | 0x020 – 0x0FC | program | HPS → FPGA | trading program (`fpga_program[]`, `FPGA_PROGRAM_BASE = 8`) |
| 64 | 0x100 | `BUY_PRICE` | HPS → FPGA | last buy-side trade price x 10000 |
| 65 | 0x104 | `SELL_PRICE` | HPS → FPGA | last sell-side trade price x 10000 |
| 66 | 0x108 | `SIGNAL` | FPGA → HPS | 0 = none, 1 = buy, 2 = sell |
| 67 | 0x10C | `HEARTBEAT` | FPGA → HPS | incremented once per strategy loop (CPU-alive proof) |
| 68 | 0x110 | `BUY_SIZE` | HPS → FPGA | last buy-side trade size |
| 69 | 0x114 | `SELL_SIZE` | HPS → FPGA | last sell-side trade size |
| 70 – 1023 | 0x118 – 0xFFF | free | — | — |

The program area currently holds 45 words (`trading.asm`); words
53 – 63 are spare.

## 3. Boot sequence (self-starting CPU)

The on-chip RAM powers up zeroed, and on this CPU a fetched word of
`32'b0` parks the control FSM in a halt state that keeps polling the
word at the PC (`FSMTrial`, state `hlt`). This is turned into the
boot mechanism:

1. After FPGA configuration the CPU sits with `PC = 8`, watching
   word 8 (steady `8` on the HEX0 debug display).
2. The HPS program writes the 45 program words starting at word 8
   (order does not matter). While the loader is still filling in
   later words, the CPU executes what is already there and re-enters
   the wait state on the first zero word it fetches - it
   self-synchronizes with the loader.
3. As soon as the full program is present the CPU runs the strategy
   loop forever and bumps `HEARTBEAT` each iteration.
4. The HPS program waits for `HEARTBEAT != 0` before connecting to
   the market feed (the `wait_for_cpu()` step, ~5 s timeout).

No reset line between HPS and FPGA is required. Re-running the
loader re-starts the CPU the same way.

## 4. Runtime protocol

HPS → FPGA (on every Coinbase match message, throttled to 200 ms):

```
fpga_regs[64] = price_x_10000    // side == buy
fpga_regs[68] = size
   or
fpga_regs[65] = price_x_10000    // side == sell
fpga_regs[69] = size
```

FPGA → HPS (polled by the C program every 100 ms):

```
signal = fpga_regs[66]:
    1 -> send "buy"  order to Alpaca, then write 0 back
    2 -> send "sell" order to Alpaca, then write 0 back
    0 -> nothing
```

Handshake rules:

* The CPU **re-raises** the signal every loop (~2 us) while the
  triggering condition persists. The HPS clears the word after
  acting; a 1 s cooldown in the C program rate-limits order bursts.
* Prices are unsigned 32-bit fixed point (x 10000); BTC near
  $100,000 gives ~1e9, safely below the signed-32-bit midpoint the
  CPU's comparisons assume.
* Sizes are whole coins (truncated).

## 5. Strategy implemented by `trading.asm`

Constants: threshold = 100000 = $10.00; registers R1/R2/R3 hold the
word addresses of `BUY_PRICE`/`SELL_PRICE`/`SIGNAL`, R12 the
`HEARTBEAT` address.

```
loop:
    buy  = LOAD(BUY_PRICE);  sell = LOAD(SELL_PRICE)
    heartbeat++
    if buy == 0 or sell == 0: loop          // wait for data
    if buy < sell:                SIGNAL 1  // crossed market - buy
    else if anchor exists:
        if buy  < last_buy  - 10$:  SIGNAL 1   // dipped - buy
        if sell > last_sell + 10$:  SIGNAL 2   // spiked - sell
    last_buy = buy; last_sell = sell         // update anchors
    goto loop
```

Branch condition mapping (hardware): after `CMP a, b`, flag N = 1
iff `a < b` (signed); the `BGT` (cond `0110`) branch is taken when
N = 1, `BEQ` when Z = 1, `BUC` always.

## 6. Instruction encoding summary

```
R-type : 0000 <rd:4>   <op:4>    <rs:4>            upper 16 bits zero
I-type : <imm[23:8]>   <op:4>    <rd:4>  <imm[7:0]>
LOAD   : 0100 <rd:4>   0000 <raddr:4>              R[rd] = RAM[R[raddr]]
STOR   : 0100 <rdata:4> 0100 <raddr:4>             RAM[R[raddr]] = R[rdata]
BRANCH : 1100 <cond:4> <disp:8>                    disp relative to branch, signed
JUMP   : 0100 <cond:4> 1100 <rtarget:4>            PC = R[rtarget], absolute
HALT   : 32'b0                                        wait for a non-zero word at PC
```

Opcodes: `AND=1 OR=2 XOR=3 ADD=5 ADDU=6 ADDC=7 LSH=8 SUB=9 SUBC=A
CMP=B ASH=D MUL=E MOV=F`. See `3710ProjectReview.pdf` for the full
flag semantics and `Software/Assembler.py` for the reference
encoder.
