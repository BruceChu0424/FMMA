# 5. FPGA design

Target: Terasic DE1-SoC, Cyclone V `5CSEMA5F31C6`, Quartus Prime 25.1std Lite.

## 5.1 Top level

[`../Software/HFTtop.v`](../Software/HFTtop.v) is the entity Quartus
compiles. (`Code/HFTtop.v` is a byte-identical archive copy; only one of them
is in the QSF, because two definitions of the same module would collide.)

| Port | Direction | Pin | Standard | Purpose |
|------|-----------|-----|----------|---------|
| `CLOCK_50` | in | `PIN_AF14` | 3.3-V LVTTL | 50 MHz board oscillator |
| `KEY[0]` | in | `PIN_AA14` | 3.3-V LVTTL | CPU reset, active low |
| `HEX0[6:0]` | out | `AE26 AE27 AE28 AG27 AF28 AG28 AH28` | 3.3-V LVTTL | debug display |
| `HPS_DDR3_*` | various | placed by the HPS hard IP | SSTL-15 / differential SSTL-15 | HPS SDRAM conduit |

The top level is deliberately thin - it says how four things are wired to
the board and nothing else:

| Module | File | Responsibility |
|--------|------|----------------|
| `HPSfgpa2` | generated | the HPS plus the 4 KB dual-port on-chip RAM |
| `cpu_core` | `Code/cpu_core.v` | the CPU: datapath, control, register bank, next-PC |
| `reset_ctrl` | `Code/reset_ctrl.v` | power-on reset and the `KEY[0]` button |
| `decoder` | `Code/decoder.v` | the seven-segment debug display |

All of the interesting behaviour is in the CPU
([03](03-cpu-microarchitecture.md)) and the memory contract
([07](07-shared-memory-protocol.md)). Splitting `cpu_core` out of the top
level also means the CPU can be instantiated against a plain memory in a
testbench without dragging in the HPS.

## 5.2 The Qsys system

`Software/HPSfgpa2.qsys` instantiates three components:

| Instance | Kind | Configuration |
|----------|------|---------------|
| `clk_0` | clock source | 50 MHz |
| `hps_0` | Cyclone V Hard Processor System | lightweight H2F bridge enabled; DDR3 conduit exported; all peripheral pin muxing left unused (see §5.7) |
| `onchip_memory2_0` | on-chip memory | 4096 bytes = 1024 × 32, true dual port, single clock, 1-cycle read latency, **no initialisation file**, **`OLD_DATA`** mixed-port read-during-write |

Connections:

```
clk_0.clk ──┬── hps_0.h2f_lw_axi_clock
            ├── hps_0.h2f_axi_clock
            ├── hps_0.f2h_axi_clock
            ├── hps_0.f2h_sdram0_clock
            └── onchip_memory2_0.clk1

hps_0.h2f_lw_axi_master ──(avalon, base 0x0000)──► onchip_memory2_0.s1
onchip_memory2_0.s2 ──────(exported as fpga_bram_s2)──► the CPU
hps_0.h2f_reset ──┬── clk_0.clk_in_reset
                  └── onchip_memory2_0.reset1
```

Two consequences worth stating explicitly:

* **The lightweight bridge runs at 50 MHz**, the same clock as the RAM and
  the CPU, so there is no clock-domain crossing anywhere in this design.
* **The RAM's base address on the bridge is 0x0000**, which is why the host
  maps `0xFF200000` and finds word 0 of the shared memory at offset 0.

The two RAM settings in bold in the table above are load-bearing and both
were wrong in the inherited design; [07](07-shared-memory-protocol.md) §7.4
and §7.6 explain why each matters.

## 5.3 Clocking

One clock, `CLOCK_50`, everywhere.

The CPU and every register it owns clock on the **falling** edge; the on-chip
RAM and the bridge clock on the **rising** edge. That is deliberate: it gives
each direction of the CPU↔RAM path half a period (10 ns) instead of needing a
wait state, and the Timing Analyzer derives the launch and latch edges from
each register's clock sense, so one `create_clock` constrains it correctly.

There is no PLL in the fabric. The HPS SDRAM PLL belongs to the hard IP.

## 5.4 Reset

`Code/reset_ctrl.v`:

```
                 KEY[0] ──► 2-stage synchroniser ──┐
                                                    ├──► active
   power-on 5-bit counter (16 clocks) ─────────────┘
                                                    ├──► rst_high  (registers)
                                                    └──► rst_low_n (control FSM)
```

The counter is held at zero while the button is down, so the full
16-clock release delay applies again after every press, and bounce needs
no separate filter: each bounce edge simply extends the reset.

The two polarities are inherited: the register bank, PC, IR and flag register
take an active-high reset, the control FSM an active-low one. Both are driven
from the same signal, inverted once.

The Qsys system has no external reset port. Its interconnect and RAM are
reset from the HPS's `h2f_reset` output, which the HPS asserts while it
boots. The fabric CPU is independent of that — it starts as soon as the FPGA
is configured, whether or not Linux is up.

## 5.5 Debug display

`HEX0` shows the low nibble of the program counter through a common-anode
seven-segment decoder (segment lit = 0). In practice:

| What you see | What it means |
|--------------|---------------|
| steady `8` | the CPU is parked at the entry word waiting for a program — normal after configuration |
| flickering | the CPU is running; the digit is the low nibble of the PC, so it is a blur |
| steady anything else | the CPU is stuck: it has parked on a zero word somewhere other than the entry point, or it is in the `ISA_MISMATCH` loop |

That last row is the quickest on-board diagnosis available;
[15](15-troubleshooting.md) uses it.

## 5.6 Timing constraints

[`../HFTTop.sdc`](../HFTTop.sdc):

```tcl
create_clock -period 20.000 -name clk50 [get_ports {CLOCK_50}]
derive_clock_uncertainty
set_false_path -to   [get_ports {HEX0[*]}]
set_false_path -from [get_ports {KEY[0]}]
```

`HEX0` drives a human eye, and `KEY[0]` is a bouncing mechanical contact that
the design synchronises itself, so neither is a timed path. Cutting them
keeps 29 I/O paths from being silently excluded from sign-off as
*unconstrained* rather than deliberately *unconstrained*.

The HPS SDRAM interface brings its own constraints in through the `.qip`.

## 5.6a Configuration scheme

```tcl
set_global_assignment -name STRATIXV_CONFIGURATION_SCHEME "PASSIVE PARALLEL X16"
set_global_assignment -name USE_CONFIGURATION_DEVICE OFF
```

On a Cyclone V SoC the FPGA is normally configured by the HPS rather than
from a flash device: U-Boot or Linux feeds an `.rbf` to the FPGA manager,
which drives the fabric's Fast Passive Parallel port. The board's MSEL
switches select the width, and the DE1-SoC ships set for FPPx16.

`STRATIXV_CONFIGURATION_SCHEME` is the correct assignment name for this
device - Quartus reuses the Stratix-V-family name for Cyclone V, and
`CYCLONEV_CONFIGURATION_SCHEME` is rejected as illegal.

Note that this does **not** change the contents of the `.rbf`: an RBF is
the raw configuration data stream, and the width is how the controller
clocks it in, not what is in the file. Setting it is correct practice and
makes the intent explicit, but if HPS configuration fails the cause is
somewhere else - [11](11-board-bringup.md) §11.4 covers what to check.

## 5.7 Known issue: the HPS SDRAM parameters are placeholders

**This does not affect the demo, but it must not be built on.**

The HPS component in `HPSfgpa2.qsys` was left at Qsys defaults for the
SDRAM: 8-bit data, 12 row bits, 8 column bits, 300 MHz, ODT disabled, and all
peripheral pin muxing (SD/MMC, UART, Ethernet, USB) unused. The DE1-SoC
actually carries 1 GB of 32-bit DDR3 at 400 MHz with four DQS groups, and it
obviously has an SD card and a UART.

Why the board still works: on a Cyclone V SoC, SDRAM is brought up by the
**preloader**, which lives on the SD card, not by the FPGA bitstream. The
Terasic image on the card carries a preloader built from the correct
parameters, so Linux boots and the bridge works regardless of what this
project's Qsys file claims.

Why it matters anyway:

* `hps_isw_handoff/` in this repository describes the wrong chip. Anyone who
  runs `bsp-create-settings` on it and builds a preloader will get a board
  that hangs before U-Boot with no console output to explain why. **Do not
  build a preloader from this handoff.**
* The `HPS_DDR3_*` port widths in the top level (`DQ[7:0]`, one DQS pair, one
  DM, `ADDR[12:0]`) follow the wrong parameters, which is why the fitter
  reports 37 pins without an exact location assignment (Critical Warning
  169085) and leaves the rest of the DDR3 net reserved.

Fixing it properly means opening the system in Platform Designer on a machine
with the full EMIF IP stack, setting the DE1-SoC part (32-bit DQ, 4 DQS
groups, row 15, col 10, bank 3, 400 MHz, RTT_NOM = RZQ/6) and the golden
reference design's pin muxing, widening the `HPS_DDR3_*` ports and
regenerating the `__hps_sdram_p0` assignment block. That is a task for
whoever next has a full Quartus Standard installation; it is tracked in
[16](16-project-plan.md).

## 5.8 Source file inventory

From [`../HFTTop.qsf`](../HFTTop.qsf), in compile order:

| File | Role |
|------|------|
| `Software/HPSfgpa2/synthesis/HPSfgpa2.qip` | the generated Qsys system |
| `Software/HPSfgpa2/synthesis/submodules/altera_mem_if_hard_memory_controller_top_cyclonev.sv` | EMIF, hand-supplied (§5.9) |
| `Software/HPSfgpa2/synthesis/submodules/altera_mem_if_oct_cyclonev.sv` | EMIF, hand-supplied |
| `Software/HPSfgpa2/synthesis/submodules/altera_mem_if_dll_cyclonev.sv` | EMIF, hand-supplied |
| `Software/HPSfgpa2/synthesis/submodules/HPSfgpa2_mm_interconnect_0_avalon_st_adapter_error_adapter_0.sv` | interconnect, hand-supplied |
| `HFTTop.sdc` | timing constraints |
| `Software/HFTtop.v` | top level: ports, Qsys, cpu_core, reset_ctrl, display |
| `Code/cpu_core.v` | the CPU, assembled from the modules below |
| `Code/reset_ctrl.v` | power-on reset and the reset button |
| `Code/PC.v`, `IR`, `FR`, `registerFinal`, `MUX16to1`, `MUX2to1`, `ALUFinal`, `FSMTrial`, `disp`, `Encoder4to16`, `decoder.v` | CPU submodules |

Note that most of the CPU files have no `.v` extension. That is inherited
from the ECE 3710 archive; Quartus is told their type explicitly in the QSF
and Icarus is given them on the command line, so it works, but it is a
nuisance and is why the file list has to be written out by hand in several
places.

## 5.9 The four hand-supplied IP files

Quartus 25.1 **Lite** does not ship the EMIF/UniPHY generation stack, so
`qsys-generate` cannot produce four of the files the system needs. They were
taken from a public mirror of an equivalent Qsys output and are listed in the
QSF directly. Port lists were checked against the instantiations in
`hps_sdram.v` before they were accepted.

**If you regenerate the Qsys system on a machine with the full IP stack,
delete those four `set_global_assignment` lines from `HFTTop.qsf` first** —
the QIP will then provide its own copies and the duplicate definitions would
collide. [BUILD-NOTES.md](BUILD-NOTES.md) has the details.

## 5.10 Resource usage and timing

See [13-test-report](13-test-report.md) for the numbers from the current
build, reproduced from `output_files/HFTTop.fit.summary` and
`output_files/HFTTop.sta.summary`, both of which are committed so the claims
can be checked against the tool output in the same revision.
