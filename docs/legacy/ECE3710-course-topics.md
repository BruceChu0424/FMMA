> **Archived — planning notes, January 2026.** The team's mapping of
> ECE 3710 and CS 3810 lecture topics onto the parts of this project they
> support. Kept as a record of how the project was scoped against the
> coursework; the dates refer to the course calendar, not to this project's
> schedule. See [`../16-project-plan.md`](../16-project-plan.md) for the
> actual plan.

---

TOPICS:

Jan 10: Intro to the course. Logic Functions, Truth Tables, Boolean Algebra

Jan 12: Boolean Algebra, DeMorgan's laws

Jan 17: Synthesis and Implementation of Boolean Functions

Jan 19: Transistors, CMOS logic, **FPGAs + Synthesis, Verilog Intro**

Jan 24: **Verilog design styles, simulation and synthesis**

Jan 26: Review of whatever we studied so far.... putting it all in perspective.

Jan 31: Boolean Optimization, Algebra + K-Maps

Feb 2: K-Maps, and Don't Care conditions

Feb 7: Finishing Ch 2: Multi-level logic + CAD

Feb 9: **Number Representation, Adders**

Feb 14: **Signed numbers + Two's complement adders**

Feb 16: **Fast adders and array multipliers**

Feb 21: **More 2's complement, Carry versus overflow, and Fast adders**

Feb 23: **Chapter 4: Combinational Logic and Building Blocks**

Feb 28: **Mux, decoders, comparators, etc.**

Mar 14: **Behavioral Verilog**

Mar 16: **Chapter 4 completion, Sequential Ckt. Intro to Latches, DFFs and Verilog.**

Mar 21 : **Seq Ckts contd. (FFs, memory, regfiles)**

Mar 23: **Verilog for registers and memories, counters**

Mar 28: Combinational + Sequential design concepts (counters)

Mar 30: **Timing issues in sequential circuit design, clocking, skew**

Apr 4: **Timing issues and Ch 5 conclusion. Begin Finite State Machines (FSM)**

Apr 6: **Finite state machines (FSM)**

April 11: **FSM Optimizations**

Apr 13: **FSM Optimizations + Analysis**

Apr 18: FSM Applications -- CPU design

Apr 20: Advanced Digital Design Concepts - CAD Techniques

Apr 25: CAD Techniques, Testing and Formal Verification



**Absolutely Essential (You cannot build this without these)**



**These are the core skills you would directly use when implementing a market-making algorithm on an FPGA.**

Jan 19: FPGAs + Synthesis, Verilog Intro

Jan 24: Verilog design styles, simulation and synthesis

Mar 14: Behavioral Verilog



***Why it matters* -** \*\*Your entire trading algorithm will be written in Verilog (\*\*Market data processing, pricing logic, order generation = HDL modules)



*Behavioral Verilog lets you express algorithmic logic cleanly before optimizing*



Market maker components

* Order book parser
* Price computation pipeline
* Order generation logic



🔹 Number Representation \& Arithmetic



Feb 9: Number Representation, Adders

Feb 14: Signed numbers + Two's complement

Feb 16–21: Fast adders, multipliers, overflow



***Why it matters* - Market making is math-heavy** (Prices, spreads, inventory, PnL = numeric logic)



FPGA trading uses fixed-point arithmetic, not floating point

Market maker components

Mid-price calculation

Spread calculation

Inventory-based skew

Risk limits



**This is critical for latency and correctness.**



🔹 Combinational Logic \& Building Blocks



Feb 23–28: Adders, muxes, comparators, decoders



***Why it matters* - Trading decisions must happen in nanoseconds** (Comparators decide when to place, cancel, or modify orders, MUXes select pricing paths (normal vs volatile market))



Market maker components

* Price comparison
* Threshold checks
* Best bid/ask selection



🔹 Sequential Logic (Registers, Memory, Counters)



Mar 16–23



***Why it matters* - Markets are stateful**

You must remember:

* Current inventory
* Outstanding orders
* Last prices
* Timers
* Market maker components
* Inventory tracking
* Outstanding order tracking
* Time-based logic (timeouts, refresh rates)



🔹 Timing, Clocking, and Latency



Mar 30 – Apr 4



***Why it matters* - FPGA trading is all about deterministic low latency** (A correct algorithm that misses timing is useless and Clock skew and setup/hold violations can cause silent financial losses)



Market maker components

* Pipelined price calculations
* Deterministic reaction time to market events



🔹 Finite State Machines (FSMs)



Apr 4–13



***Why it matters* - Market making is naturally an FSM:**



States like:

* IDLE
* WAIT\_FOR\_MARKET\_DATA
* COMPUTE\_PRICE
* SEND\_ORDER
* WAIT\_FOR\_ACK
* CANCEL / MODIFY



1. Market maker components
2. Exchange protocol handling
3. Order lifecycle management
4. Error recovery



**This is one of the most important topics for FPGA trading.**











**2️⃣ Important but Secondary (Helps performance \& scale)**



*These topics improve efficiency, optimization, and correctness, but you could build a simple system without mastering all of them initially.*



🔹 Boolean Optimization \& K-Maps



Jan 31 – Feb 7



***Why it matters* - Helps reduce logic depth, Lower depth = lower latency** (Often handled automatically by synthesis tools, but knowledge helps)



Used for: Optimizing hot decision paths



🔹 FSM Optimization



Apr 11–13



***Why it matters* - Fewer states = faster reaction, Less logic = higher clock frequency**



Used for

* High-frequency order handling
* Reducing jitter



🔹 CAD Techniques \& Verification



Apr 18–25



***Why it matters* - You must verify correctness before risking money** (Formal verification is used heavily in real trading firms)



Used for

* Ensuring no invalid order states
* Preventing race conditions













**CS 3810 important topics:**


✅ Ordered by Relevance (Most → Least)

1️⃣ CPU Pipelining, Hazards, and Performance



(Single-cycle, pipelined CPUs, data/control hazards, branch behavior)



Why this is #1



FPGA market makers are custom pipelines



Understanding hazards teaches you how to:



Avoid stalls



Balance pipeline stages



Maintain one-result-per-cycle throughput



➡️ This knowledge transfers directly to trading datapaths.



2️⃣ Cache \& Memory Hierarchy Concepts



(Caches, locality, associativity)



Why this is #2



Even though FPGAs don’t use caches:



You must design around memory latency



Decide what lives in registers vs BRAM vs DRAM



➡️ Teaches what not to do in low-latency design.



3️⃣ Instruction Set Architecture (MIPS)



(Branches, loops, comparisons, procedures)



Why this is #3



Helps you understand:



Control flow costs



Branch unpredictability



Instruction-level dependencies



➡️ Critical for understanding why software market making is slow.



4️⃣ Software vs Hardware Parallelism



(Concurrency models, multiple-issue, vector CPUs)



Why this is #4



Reinforces why FPGAs win:



True parallelism



No shared instruction stream



➡️ Strategic understanding, less tactical.



5️⃣ Compilation (C → Machine Code)



(How high-level code becomes instructions)



Why this is #5



Explains where latency sneaks in



Useful when deciding:



What logic belongs in FPGA



What stays in software



➡️ Indirect but valuable.

