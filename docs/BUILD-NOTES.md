# Build notes (Windows / Quartus Prime 25.1 Lite)

An appendix to [10-build-guide](10-build-guide.md). This records the
non-obvious things that had to be done to get the Quartus and Qsys flow
working on this particular machine, so the knowledge is not lost when
somebody hits the same wall.

Almost all of it comes from one root cause: the installed Quartus is
**25.1std.0 SC Lite Edition**, which does not ship the HPS EMIF/UniPHY
generation stack.

## 1. Nios II command shell mis-detects WSL2 (fixed)

`D:\Software\nios2eds\nios2_command_shell.sh` detected WSL with
`grep -q Microsoft /proc/version`. WSL2 kernels report
`microsoft-standard-WSL2` in **lowercase**, so the check failed and the
shell put a non-existent Linux toolchain directory on `PATH`
(`H-i686-pc-linux-gnu/bin`). Sequencer builds then died with `make: not
found` and `uniphy_mcc.exe: child process exited abnormally`.

Applied:

* `nios2_command_shell.sh`: the grep is now case-insensitive
  (`grep -qi microsoft`).
* `D:\Software\nios2eds\bin\gnu\H-x86_64-mingw32\bin\make` (no extension):
  a small `sh` shim that execs the `make.exe` next to it, so a bare `make`
  resolves on the WSL-side `PATH`.
* `Nios II Command Shell.bat` replaced with a native Windows version
  (original kept as `.bat.orig`) that sets `QUARTUS_ROOTDIR` and
  `SOPC_KIT_NIOS2` and prepends `nios2eds`, `quartus` and `Git\usr\bin` to
  `PATH`. This avoids the WSL interop layer entirely.

With these, `qsys-generate` runs its sequencer `make` step natively. Only
the EMIF IP problem below still stops a full generation.

These are edits to the **Quartus installation**, not to this repository. A
fresh machine will need them again.

## 2. Missing EMIF/UniPHY IP

`qsys-generate --synthesis=VERILOG Software\HPSfgpa2.qsys` stops in
`generate_hps_sdram.tcl`: the EMIF IP tree (`quartus/ip/...`,
`quartus/common/ip/altera/*emif*`, the sequencer templates `ac_rom.s` and
`inst_rom.s`) is absent from a Lite installation.

Four files a complete generation would have written into
`Software/HPSfgpa2/synthesis/submodules/` were therefore taken from a public
mirror of equivalent Qsys output and are listed directly in `HFTTop.qsf`:

| File | Role | How it was checked |
|------|------|--------------------|
| `altera_mem_if_hard_memory_controller_top_cyclonev.sv` | hard DDR controller wrapper | port list compared against the `c0` instantiation in `hps_sdram.v` — 169/169 match |
| `altera_mem_if_oct_cyclonev.sv` | OCT calibration wrapper | exact port and parameter match |
| `altera_mem_if_dll_cyclonev.sv` | DLL wrapper | exact port and parameter match |
| `HPSfgpa2_mm_interconnect_0_avalon_st_adapter_error_adapter_0.sv` | Avalon-ST error adapter, renamed from the mirror | identical generation parameters (34-bit data, no in-error, 1-bit out-error) |

> **If you regenerate the Qsys system on a machine with the full IP stack,
> delete those four `set_global_assignment` lines from `HFTTop.qsf` first.**
> The QIP will then provide its own copies, and duplicate module definitions
> would collide.

Licence provenance is recorded in
[`../THIRD-PARTY-NOTICES.md`](../THIRD-PARTY-NOTICES.md).

## 3. Two generated files are edited by hand

Same root cause: the system cannot be regenerated here, so two settings that
would normally come out of Platform Designer had to be applied to the
generated Verilog as well as to the `.qsys` source.

| Setting | In `.qsys` | In `HPSfgpa2_onchip_memory2_0.v` | Why |
|---------|-----------|----------------------------------|-----|
| `read_during_write_mode_mixed_ports` | `readDuringWriteMode = OLD_DATA` | `defparam ... = "OLD_DATA"` | With `DONT_CARE`, a read that collides with the other port's write returns undefined data, and the seqlock in [07](07-shared-memory-protocol.md) cannot be built on it. |
| RAM initialisation | `initMemContent = false`, `initializationFileName = UNUSED` | `parameter INIT_FILE = "UNUSED"` | The RAM must power up zeroed, because a zero word is the CPU's HALT instruction and that is what parks it until the loader runs. |

The `.qsys` edit is what a future regeneration will honour; the
generated-file edit is what the current build actually compiles. Both are
annotated in place.

**After regenerating**, confirm the regenerated file says `"OLD_DATA"` and
`"UNUSED"`, and delete the hand edits.

### What this fixed

The RAM's initialisation file used to be
`C:/intelFPGA_lite/ECE 3710/ECE3710_Project/Mif4.mif` — an absolute path on
the original ECE 3710 machine. Quartus could not find it, emitted **Critical
Warning 127003** and initialised the RAM to zero. The boot contract
therefore held by accident, and would have broken the moment anyone supplied
a file at that path. That warning is now gone from the build.

## 4. HPS DDR3 pin I/O standards (fixed)

The first fit attempt failed with 363 errors of the form *"output buffer atom
... has port SERIESTERMINATIONCONTROL[0] connected, but does not use
calibrated on-chip termination"* and *"I/O HPS_DDR3_DQ[n] has dynamic
termination control connected, but does not use parallel termination"*.

Cause: no I/O standard assignments existed for the HPS DDR3 pins, so they
defaulted to 2.5 V — a standard without calibrated OCT, while the generated
PHY connects the OCT calibration chain to every pad.

Fix: `HFTTop.qsf` carries the `__hps_sdram_p0` assignment block that a normal
Qsys generation writes into the project — SSTL-15 Class I on the
single-ended pins, differential 1.5-V SSTL Class I on CK and DQS, calibrated
50-ohm series and parallel termination on DQ/DQS/DM, maximum drive on
address and control. Adapted from a public DE1-SoC project's `.qsf` to this
system's widths.

**Do not delete this block.** Without it the fit fails outright.

## 5. Nine QSF assignments were being silently discarded (fixed)

The `__hps_sdram_p0` block also contained `GLOBAL_SIGNAL OFF` assignments for
`dq_ddio[1..3]`, `reset_n_fifo_write_side[1..3]` and
`reset_n_fifo_wraddress[1..3]`, plus a `PLL_COMPENSATION_MODE` assignment
naming `pll0`.

None of them applied. This configuration instantiates exactly **one** DQS
group, so the `[1..3]` nodes do not exist, and the PLL instance in this
netlist is called `pll`, not `pll0`. The fitter listed all of them under
*Ignored Assignments* and raised Warning 171167, while anyone reading the
QSF would reasonably believe the UniPHY reset tree was being kept off the
global clock network.

The nine dead assignments were removed and the PLL name corrected. The
Ignored Assignments table in `output_files/HFTTop.fit.rpt` went from 23
entries to 14.

Six of the remainder still do not apply, and correcting the instance name
did not help:

```
PLL Compensation Mode   ...|hps_sdram_inst|pll|fbout
Global Signal           ...|dq_ddio[0].read_capture_clk_buffer
Global Signal           ...|reset_n_fifo_wraddress[0]
Global Signal           ...|reset_n_fifo_write_side[0]
Global Signal           ...|phy_reset_mem_stable_n
Global Signal           ...|phy_reset_n
```

These name real nodes, but on a Cyclone V **SoC** the HPS DDR3 PHY is hard
logic, not a soft UniPHY instance in the fabric, so there is no fabric
global clock network for a `GLOBAL_SIGNAL OFF` to turn off and no soft PLL
whose compensation mode can be set. The whole `__hps_sdram_p0` block is a
template written for a soft memory controller; these six lines are the part
that can never apply to a hardened one.

They are harmless — the fitter discards them — and they could be deleted
too. They were left in place because removing them changes nothing in the
netlist and would cost another 48-minute compile to re-verify. Anyone
touching this block should delete them at the same time.

The remaining eight entries are *Fast Output Enable Register* assignments
that come from inside the IP itself and are expected.

## 6. Sequencer ROM hex files

`hps_sdram_p0.sdc` references `hps_AC_ROM.hex` and `hps_inst_ROM.hex` at the
project root, which `uniphy_mcc` would have generated from the DDR3
parameters. They are not in the repository and Quartus does not complain
about them in this flow, because DDR calibration on this board belongs to
the HPS preloader on the SD card — the board boots Linux regardless of what
the FPGA design says about SDRAM. See [05](05-fpga-design.md) §5.7, which is
the fuller version of this story and explains why the whole SDRAM
configuration here is a placeholder.

## 7. Command-line build

```
cd D:\Projects\OrCAD\FMMA
D:\Software\quartus\bin64\quartus_map.exe HFTTop      # analysis + synthesis only
D:\Software\quartus\bin64\quartus_sh.exe --flow compile HFTTop
```

Roughly an hour, almost all of it in the fitter. Programming file:
`output_files/HFTTop.sof`.

Expected: **0 errors**, and exactly two Critical Warnings — 169085 and
174073, both about HPS DDR3 pin placement, both explained in
[05](05-fpga-design.md) §5.7. If Critical Warning 127003 reappears, see §3.

Current results are in [13-test-report](13-test-report.md), taken from the
committed `output_files/*.summary`.

## 8. Simulation: no Questa licence

The installed `questa_fse` refuses to start (*"Unable to checkout a
license"*). Simulation uses **Icarus Verilog 12**, installed with
`winget install Icarus.Verilog`, which lands in `C:\iverilog`.

`Testbenches/run_sim.sh` adds that to `PATH` itself, so:

```bash
Testbenches/run_sim.sh
```

is all that is needed. [12-verification-plan](12-verification-plan.md)
describes what it runs.

## 9. No C compiler on the development machine

Windows here has no POSIX toolchain, and the WSL instance has no `gcc`. The
host program is normally built on the board, but it can be checked on the PC
with Docker:

```bash
docker run --rm -v "$PWD:/work" -w /work/Software debian:bookworm-slim sh -c \
  'apt-get update -qq && apt-get install -y -qq build-essential libssl-dev python3 && make'
```

That is how `MarketStream.c` is verified to compile clean under
`-Wall -Wextra` without a board present.
