# Changelog

## 2026-09 — protocol v2, risk layer, verification

The first revision under ECE 4900. The previous state was an inherited
ECE 3710 CPU with a working HPS↔FPGA link and a first attempt at a trading
loop; this revision makes the chain correct, bounded and tested, and writes
down how it works.

### Fixed — hardware

These were all found by auditing the inherited design against its own
documentation, and each was reproduced in simulation before being changed.

* **I-type operands were reversed.** The immediate was muxed onto the ALU's
  A input instead of the B input, so every immediate instruction computed
  `imm op Rd`: `SUB Rd,#k` was `k − Rd`, `CMP Rd,#k` compared backwards, and
  `MOV Rd,#k` was a no-op. Only the commutative operations worked, which is
  why the old strategy loaded every constant with `XOR Rd,Rd` then
  `OR Rd,#k`. Moving the mux to the B input fixes all of them and leaves the
  R-type encoding bit-for-bit identical. (`Software/HFTtop.v`)
* **`LSH` and `ASH` were wrong for every right shift**, and `LSH` by zero
  right-shifted by one. The implementation always performed the left shift
  and then, whenever the negated count happened to land at 15 or below, did
  a second right shift on the already-shifted value. Replaced with a plain
  signed-amount shifter. (`Code/ALUFinal`)
* **`SUB` and `SUBC` never set the N or L flags**, so a conditional branch
  after a subtract could never be taken. (`Code/ALUFinal`)
* **`CMP`'s unsigned L flag was wrong for mixed-sign operands.** Replaced
  the sign-compare chain with direct signed and unsigned comparisons; the N
  flag every branch depends on is unchanged. (`Code/ALUFinal`)
* **`SUBC`'s carry polarity disagreed with `SUB`'s.** Both now use the same
  borrow-inverted convention. (`Code/ALUFinal`)
* **The ALU's carry input was tied to zero**, which made `ADDC` identical to
  `ADD` and made `SUBC` subtract an extra one. Wired to the flag register.
  (`Software/HFTtop.v`)
* **Condition code `1100` was decoded as `!Z or !N`**, which is true after
  every possible `CMP` — an unconditional branch with a conditional name.
  Removed, so it now behaves like every other undecoded code: not taken.
  (`Code/FSMTrial`)
* **An undefined `0100`-class encoding left the FSM's state register
  unassigned**, stalling the CPU in decode with no way out and no
  indication. It now parks in the halt state. (`Code/FSMTrial`)
* **There was no external reset.** The only way to restart the CPU was to
  reconfigure the FPGA. Added `KEY[0]`, with two synchroniser stages.
  (`Software/HFTtop.v`, `HFTTop.qsf`, `HFTTop.sdc`)

### Fixed — the shared memory

* **Mixed-port read-during-write was `DONT_CARE`.** A read of a word the
  other port was writing in the same cycle returned indeterminate data. With
  a 780 ns CPU loop that is a corrupted price every few minutes, and it makes
  a seqlock impossible to build. Now `OLD_DATA`.
* **The on-chip RAM was configured to initialise from
  `C:/intelFPGA_lite/ECE 3710/ECE3710_Project/Mif4.mif`**, an absolute path
  on a different machine. Quartus could not find it, warned (Critical
  Warning 127003) and zeroed the RAM — so the "RAM powers up zeroed" boot
  contract held only by accident, and would have broken the moment anyone
  supplied that file. Now explicitly no initialisation file.

### Fixed — the host program

* **`make` produced a binary that could not connect to anything.** No
  `-DMG_TLS` meant mongoose compiled with TLS disabled, and every `wss://`
  and `https://` connection failed at the handshake — silently, because the
  program turns mongoose's logging down. Now `-DMG_TLS=MG_TLS_OPENSSL`.
* **`-std=c11` broke the build outright** by hiding `clock_gettime`,
  `usleep` and `mmap` behind `__STRICT_ANSI__`. Now `-std=gnu11`.
* **mongoose's built-in TLS cannot talk to Coinbase** even when enabled: it
  rejects P-384 certificate intermediates, and Coinbase is fronted by
  Cloudflare. This is why the backend is OpenSSL and not the built-in stack.
* **TLS verified nothing.** `.ca = mg_str("")` disables the trust anchor
  check, leaving only host-name matching. Now loads the system CA bundle.
* **The feed never reconnected.** One `mg_ws_connect` at startup, return
  value ignored, no close or error handler. Now reconnects with exponential
  backoff.
* **Alpaca's HTTP status was never checked**, so a rejected order was
  indistinguishable from a filled one. Now checked, logged, and only a 2xx
  reports a fill.
* **Trade sizes were always written as zero** — a fractional BTC size cast
  to `unsigned`. Now parsed with their own scale.
* **Prices went through a `float`.** 24 bits of mantissa for a value needing
  30, so the advertised precision was not delivered. Now parsed as exact
  integers, and clamped so a bad quote cannot wrap into the sign bit.
* **`Coinbase "matches"` is not a bid and an ask.** The `side` field is the
  *maker* side, so the two words the strategy compared were the last
  taker-buy print and the last taker-sell print. Switched to the `ticker`
  channel, which carries real `best_bid` and `best_ask`.
* **A loader failure was ignored** and the program carried on against
  unverified memory. Now exits with a specific code.
* The shutdown path was unreachable; `/dev/mem` and the mapping were never
  released. Now handled on `SIGINT`/`SIGTERM`.

### Added

* **Protocol v2** (`docs/07`): a seqlock for market data, publish-last
  sequencing for decisions, disjoint write regions so the two RAM ports can
  never collide, and a version gate.
* **A risk layer in hardware** (`docs/09`): position tracking from fill
  reports, a configurable position limit checked before every signal, a
  master switch, reject counting and status reporting. All of it on the
  decision path in the fabric, so a broken host cannot bypass it.
* **Latency instrumentation** (`docs/14`): every signal carries the sequence
  number of the quote that caused it, so the host can attribute latency
  exactly; plus a software reference strategy (`--bench`) for comparison.
* **Software restart** (`CFG_RESTART`) so the host can reload a program and
  restart the engine without touching the board.
* **A datapath probe** in `trading.asm` that withholds `FW_VERSION` unless
  the bitstream implements the ISA the program was built for.
* **A generated memory map.** `Software/protocol.py` is the single
  definition and emits the C header, the assembler include and the Verilog
  header, so the three cannot drift. `make check-generated` enforces it.
* **A golden-reference simulator** (`Software/fmma_sim.py`) and an
  equivalence test against the RTL (`Testbenches/tb_alu.v`, ~9,500 generated
  vectors).
* **A test suite where there was none**: 82 Python tests, a 31-assertion
  full-chain RTL testbench driven through the real bridge port, a timing
  budget testbench, and one script that runs all of it in 25 seconds.
* **Documentation**: the `docs/` tree, `CONTRIBUTING.md`,
  `THIRD-PARTY-NOTICES.md` and a `LICENSE`.

### Changed

* Price scale from ×10000 to ×100 (cents). The strategy sums bid and ask,
  and the old scale put that sum about 7 % below the point where the signed
  comparisons invert — at BTC prices, far too close.
* The strategy now works on the doubled mid (`bid + ask`) against an anchor,
  replacing a "crossed market" test that compared two numbers which were
  never a bid and an ask.
* The memory map moved from words 64–69 to two disjoint blocks at 256 and
  320, with the program area grown from 56 to 248 words.
* `LDI` is one instruction instead of two, now that `MOV` with an immediate
  works.
* Branch mnemonics are now truthful. Eight of the fifteen the old assembler
  accepted mapped to condition codes the hardware does not decode; they
  assembled cleanly and were silently never taken. The assembler rejects
  them and names the alternative.
* Debug `$display` statements removed from the control FSM.
* `HFTTop.qsf`: removed nine instance assignments naming DQS groups that do
  not exist in this configuration (the fitter was discarding all of them),
  and corrected the DDR PLL instance name.
* `HFTTop.sdc`: constrained `HEX0` and `KEY[0]` instead of leaving 29 I/O
  paths silently unconstrained.
* Legacy ECE 3710 testbenches moved to `Testbenches/legacy/` with a README
  explaining what replaced each one. Four of them no longer compiled.
* `.gitignore` no longer excludes the Quartus reports, so the timing and
  utilisation numbers the documents quote can be checked against tool output
  in the same revision.

### Security

* **An Alpaca API key pair was committed in `d65ee28` and is still reachable
  in git history.** HEAD reads credentials from the environment only. The
  key must be revoked; see `docs/18-security-and-compliance.md` §18.4.
* Declared the project's licence (GPL-2.0, following from mongoose) and
  documented every third-party component.

### Known issues

* **The HPS SDRAM parameters in `HPSfgpa2.qsys` are Qsys defaults, not the
  DE1-SoC's memory.** The board works anyway, because DDR3 is brought up by
  the SD card's preloader. But `hps_isw_handoff/` describes the wrong chip
  and must never be used to build a preloader. Fixing it needs a Quartus
  installation with the EMIF IP. `docs/05` §5.7.
* Two Critical Warnings remain in the Quartus build, both about HPS DDR3 pin
  placement, both a consequence of the above.
* On-board validation of the full chain is outstanding; `docs/11` is the
  procedure.

---

## 2026-04 — HPS↔FPGA link

Writes from Linux over the lightweight bridge became visible on the
seven-segment display. Milestone presentation delivered. The Quartus flow
was got working end to end on the development machine, including the
workarounds in `docs/BUILD-NOTES.md` for Quartus Lite's missing EMIF IP.

## 2025-12 — ECE 3710

The CPU: ALU, control FSM, register bank, program counter, instruction and
flag registers, assembler, and a Fibonacci demonstration. HPS integration
attempted; embedded Linux booted and the bridge researched, but the FPGA
never successfully read data the HPS had written.

Group 1011: Henry Wilson, Bobby Lofgren, Kaleb Neilson, Carson Ord.
