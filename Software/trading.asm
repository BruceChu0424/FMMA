% ============================================================
% FMMA - FPGA Market Maker Accelerator
% trading.asm - mean-reversion strategy with risk limits
%
% Runs on the custom 32-bit RISC CPU in the FPGA fabric.  The HPS
% Linux program loads it at PROGRAM_BASE and then streams best
% bid/ask quotes into the shared RAM; the CPU decides and publishes
% a trade signal, which the HPS executes on Alpaca.
%
% Protocol version 2 - see docs/07-shared-memory-protocol.md.
% Every word index comes from fmma_protocol.inc, which is generated
% from Software/protocol.py, so this file, MarketStream.c and the
% testbenches cannot drift apart.
%
% ------------------------------------------------------------
% Strategy
% ------------------------------------------------------------
% The CPU tracks twice the mid price, sum = bid + ask, and compares
% it against the sum at the last decision point (the "anchor"):
%
%     sum < anchor - 2*THRESH   ->  the market fell   ->  BUY
%     sum > anchor + 2*THRESH   ->  the market rose   ->  SELL
%
% Working with the doubled mid avoids a divide by two, which matters
% because this CPU's shift instruction is a whole extra instruction
% and the factor of two cancels on both sides of the comparison.
% Prices are in cents (FMMA_PRICE_SCALE = 100), so bid + ask for BTC
% near $100,000 is about 2 * 10^7 - three orders of magnitude below
% the signed 32-bit limit the comparisons rely on.
%
% Every decision is filtered by the risk block before it is
% published: a buy is suppressed when the inventory is already at
% +CFG_MAX_POS, a sell when it is at -CFG_MAX_POS, and everything is
% suppressed while CFG_ENABLE is zero.  Suppressed decisions bump
% REJECTS and set the risk bit in STATUS, so the HPS can see that the
% strategy wanted to trade and was not allowed to.
%
% ------------------------------------------------------------
% Consistency
% ------------------------------------------------------------
% The HPS writes market data while the CPU is reading it, with no
% lock between them, so the market-data block is a seqlock:
%
%   HPS:  TICK_SEQ <- odd ; write BID/ASK/sizes ; TICK_SEQ <- even
%   CPU:  read TICK_SEQ, reject it if odd; read BID and ASK;
%         read TICK_SEQ again and start over if it moved.
%
% Signals travel the other way with a publish-last counter: the CPU
% writes SIGNAL and SIGNAL_TICK, then increments SIGNAL_SEQ.  The HPS
% edge-detects SIGNAL_SEQ and never writes into the output block at
% all, so no signal can be lost to a clear that races the CPU - which
% is exactly what protocol version 1 could do.
%
% ------------------------------------------------------------
% Register map
% ------------------------------------------------------------
%   R0  constant 0                R8  scratch B
%   R1  constant 1                R9  anchor (last decision's sum)
%   R2  &TICK_SEQ                 R10 scratch C
%   R3  &HEARTBEAT                R11 last TICK_SEQ consumed
%   R4  scratch address           R12 heartbeat counter
%   R5  bid                       R13 position (signed, lots)
%   R6  ask                       R14 last FILL_SEQ consumed
%   R7  scratch A                 R15 LOOP address (for JUC)
%
% Timing at 50 MHz: 3 clock cycles per instruction.  The idle path
% (heartbeat store, restart check, fill check, tick check) is 13
% instructions = 39 cycles = 780 ns, so a newly published quote is
% picked up within 780 ns and a full decision completes well inside
% 5 us.  Both numbers are asserted by test_strategy.TestTiming and
% tabulated in docs/14-latency-and-performance.md.
% ============================================================

.include "fmma_protocol.inc"

% ---------- one-time initialisation ----------
INIT:
XOR  R0, R0                 % R0 = 0 even if a previous program left junk
LDI  R1, #1
LDI  R2, #TICK_SEQ
LDI  R3, #HEARTBEAT

XOR  R9,  R9                % anchor      = 0 (means "no anchor yet")
XOR  R11, R11               % last tick   = 0 (re-anchor on the next quote)
XOR  R12, R12               % heartbeat   = 0

% The inventory is NOT reset to zero. A restart must not make the CPU
% forget a position that really exists at the broker, or the risk
% limit would happily let it double up. The HPS is the authority on
% the real position and states it in CFG_POSITION.
LDI  R4, #CFG_POSITION
LOAD R13, R4

% Adopt the current FILL_SEQ rather than starting from zero, so a fill
% the HPS reported before the restart is not applied a second time.
LDI  R4, #FILL_SEQ
LOAD R14, R4

% Clear every word we own in the output block.  The RAM powers up
% zeroed, but a reload of the program must not inherit stale outputs.
XOR  R7, R7
LDI  R4, #SIGNAL
STOR R7, R4
LDI  R4, #SIGNAL_TICK
STOR R7, R4
LDI  R4, #SIGNAL_SEQ
STOR R7, R4
LDI  R4, #POSITION
STOR R13, R4                % publish the adopted inventory
LDI  R4, #REJECTS
STOR R7, R4
LDI  R4, #QUOTE_BID
STOR R7, R4
LDI  R4, #QUOTE_ASK
STOR R7, R4

LDI  R7, #STATUS_RUNNING
LDI  R4, #STATUS
STOR R7, R4

% ---------- check the bitstream matches this program ----------
% Bitstreams built before the 2026 datapath fix route an immediate to
% the ALU's A input instead of its B input, so "SUB R8, #3" computes
% 3 - R8 rather than R8 - 3 and "LDI Rd, #k" does nothing at all.  A
% program assembled for the fixed ISA would run on such a bitstream
% and quietly compute nonsense, which for a trading system means real
% orders on garbage arithmetic.  Prove the wiring before declaring a
% version; FW_VERSION is what the HPS loader waits for, so failing
% here stops the whole chain rather than corrupting it.
LDI  R8, #10
SUB  R8, #3                 % must be 7 on a correct datapath
LDI  R7, #7
CMP  R8, R7
BNE  ISA_MISMATCH

% FW_VERSION is written last: the HPS treats it as "the CPU is up and
% speaks the protocol I was built against".
LDI  R7, #PROTOCOL_VERSION
LDI  R4, #FW_VERSION
STOR R7, R4

LDI  R15, #LOOP

% ============================================================
% Main loop
% ============================================================
LOOP:
ADD  R12, R1                % heartbeat++
STOR R12, R3

% ---------- has the HPS asked for a restart? ----------
% CFG_RESTART sits immediately before FILL_SEQ so one LDI serves both
% checks: the restart test reads through R4 and the fill test reaches
% FILL_SEQ with a single ADD.
LDI  R4, #CFG_RESTART
LOAD R8, R4
CMP  R8, R0
BNE  DO_RESTART

% ---------- apply any fill the HPS has reported ----------
% This sits ahead of the tick check so POSITION is accurate as soon as
% the HPS reports a fill, rather than only when the next quote arrives,
% and so the risk check below always works from an up-to-date inventory.
ADD  R4, R1                 % R4 = &FILL_SEQ
LOAD R8, R4
CMP  R8, R14
BEQ  NOFILL
MOV  R14, R8
LDI  R4, #FILL_SIDE
LOAD R8, R4
LDI  R4, #FILL_QTY
LOAD R4, R4                 % R4 = quantity
CMP  R8, R1                 % FILL_BOUGHT == 1
BNE  FILL_WAS_SOLD
ADD  R13, R4                % we bought: inventory grows
BUC  FILL_DONE
FILL_WAS_SOLD:
SUB  R13, R4                % we sold: inventory shrinks
FILL_DONE:
LDI  R4, #POSITION
STOR R13, R4
NOFILL:

% ---------- has a new quote arrived? ----------
LOAD R7, R2                 % R7 = TICK_SEQ
CMP  R7, R11
BEQ  LOOP                   % no new tick - idle path ends here

% ---------- seqlock read of the market-data block ----------
MOV  R8, R7
AND  R8, R1
CMP  R8, R0
BNE  LOOP                   % odd: the HPS is mid-update, try again

MOV  R4, R2
ADD  R4, R1                 % &BID
LOAD R5, R4
ADD  R4, R1                 % &ASK
LOAD R6, R4

LOAD R8, R2                 % re-read TICK_SEQ
CMP  R8, R7
BNE  LOOP                   % it moved: the snapshot is torn, try again

MOV  R11, R7                % commit: this tick is consumed

% ---------- need both sides of the book ----------
CMP  R5, R0
BEQ  LOOP
CMP  R6, R0
BEQ  LOOP

% ---------- sum = bid + ask (twice the mid) ----------
MOV  R7, R5
ADD  R7, R6

CMP  R9, R0
BEQ  SET_ANCHOR             % first valid tick: just anchor

LDI  R4, #CFG_THRESH
LOAD R8, R4
ADD  R8, R8                 % R8 = 2 * THRESH, to match the doubled mid

MOV  R10, R9
SUB  R10, R8                % R10 = anchor - 2*THRESH
CMP  R7, R10
BLT  DO_BUY                 % the market fell through the band

MOV  R10, R9
ADD  R10, R8                % R10 = anchor + 2*THRESH
CMP  R10, R7
BLT  DO_SELL                % the market rose through the band

SET_ANCHOR:
MOV  R9, R7
JUC  R15

% ============================================================
% Decisions
% ============================================================
DO_BUY:
MOV  R9, R7                 % re-anchor at the decision point
LDI  R4, #CFG_ENABLE        % the master switch outranks the risk check,
LOAD R8, R4                 % so a disabled desk reports "disabled" rather
CMP  R8, R0                 % than whatever the inventory happens to be
BEQ  DISABLED_BLOCK
LDI  R4, #CFG_MAX_POS
LOAD R8, R4
CMP  R13, R8
BLT  BUY_ALLOWED            % position < +MAX_POS
BUC  RISK_BLOCK
BUY_ALLOWED:
LDI  R7, #SIGNAL_BUY
BUC  EMIT

DO_SELL:
MOV  R9, R7
LDI  R4, #CFG_ENABLE
LOAD R8, R4
CMP  R8, R0
BEQ  DISABLED_BLOCK
LDI  R4, #CFG_MAX_POS
LOAD R8, R4
XOR  R10, R10
SUB  R10, R8                % R10 = -MAX_POS
CMP  R10, R13
BLT  SELL_ALLOWED           % -MAX_POS < position
BUC  RISK_BLOCK
SELL_ALLOWED:
LDI  R7, #SIGNAL_SELL
BUC  EMIT

% ---------- publish ----------
EMIT:
LDI  R4, #SIGNAL
STOR R7, R4
LDI  R4, #SIGNAL_TICK
STOR R11, R4

LDI  R7, #STATUS_RUNNING    % clear the blocked bits
LDI  R4, #STATUS
STOR R7, R4

% SIGNAL_SEQ is written last: it is what the HPS edge-detects, so
% everything it describes must already be in memory.
LDI  R4, #SIGNAL_SEQ
LOAD R8, R4
ADD  R8, R1
STOR R8, R4
JUC  R15

% ---------- suppressed ----------
RISK_BLOCK:
LDI  R7, #STATUS_RISK_BLOCKED
BUC  COUNT_REJECT

DISABLED_BLOCK:
LDI  R7, #STATUS_DISABLED

COUNT_REJECT:
ADD  R7, R1                 % + STATUS_RUNNING (which is 1)
LDI  R4, #STATUS
STOR R7, R4
LDI  R4, #REJECTS
LOAD R8, R4
ADD  R8, R1
STOR R8, R4
JUC  R15

% ---------- software restart ----------
% The HPS has no reset line into the fabric, so this is how a freshly
% loaded program is started from a known state. Clear the request
% first, so a restart cannot loop, then re-enter the init block.
DO_RESTART:
XOR  R8, R8
STOR R8, R4                 % R4 still points at CFG_RESTART
LDI  R4, #INIT
JUC  R4

% ---------- datapath mismatch ----------
% The bitstream is older than this program.  Keep the heartbeat going
% so the HPS can tell the CPU is alive, but never write FW_VERSION:
% the loader reports the mismatch and refuses to trade.  Reprogram
% output_files/HFTTop.sof to clear it.
ISA_MISMATCH:
ADD  R12, R1
STOR R12, R3
LDI  R4, #ISA_MISMATCH
JUC  R4
