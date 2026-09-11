% ============================================================
% FMMA - FPGA Market Maker Accelerator
% market_maker.asm - two-sided quoting with inventory skew
%
% The other strategy in this repository, trading.asm, is a
% mean-reversion trigger: it reacts to a move.  This one is what
% the project is named for.  It continuously computes a bid and an
% ask around the mid, leans them against whatever inventory it is
% carrying, and signals a trade when the market comes to its price.
%
% Load it the same way as trading.asm:
%     python Assembler.py market_maker.asm
%     sudo -E ./marketstream --half-spread 200 --skew 50
%
% ------------------------------------------------------------
% What it computes
% ------------------------------------------------------------
%   mid2   = bid + ask                      (twice the mid)
%   skew2  = 2 * position * CFG_SKEW        (lean against inventory)
%   qbid2  = mid2 - 2*CFG_HALF_SPREAD - skew2
%   qask2  = mid2 + 2*CFG_HALF_SPREAD - skew2
%
% Everything is carried at twice the real value so there is no
% divide in the hot path, exactly as in trading.asm; the published
% QUOTE_BID and QUOTE_ASK are halved once, at the end, with a
% single right shift.
%
% The skew is the interesting part.  Long inventory pushes BOTH
% quotes down: the ask becomes easier to hit, so the position is
% more likely to be reduced, and the bid becomes harder to hit, so
% it is less likely to grow.  Short inventory does the reverse.
% CFG_SKEW is how many price units to move per lot held.
%
% ------------------------------------------------------------
% When it trades
% ------------------------------------------------------------
%   market bid >= our ask   ->  somebody would lift us   ->  SELL
%   market ask <= our bid   ->  somebody would hit us    ->  BUY
%
% This is a simulation of resting quotes rather than resting
% quotes themselves: the host sends a market order when our price
% is reached.  Real quoting needs resting limit orders with
% cancel/replace, which the broker API in use cannot do at a
% useful latency.  docs/08 section 8.6 is explicit about the gap.
%
% ------------------------------------------------------------
% Register map
% ------------------------------------------------------------
%   R0  constant 0                R8  scratch B
%   R1  constant 1                R9  our bid  x2
%   R2  &TICK_SEQ                 R10 our ask  x2
%   R3  &HEARTBEAT                R11 last TICK_SEQ consumed
%   R4  scratch address           R12 heartbeat counter
%   R5  market bid                R13 position (signed, lots)
%   R6  market ask                R14 last FILL_SEQ consumed
%   R7  scratch A                 R15 LOOP address
%
% Requires the 2026 datapath fix (immediate operand order) and the
% rebuilt shifter; the startup probe checks both before publishing
% FW_VERSION.  See docs/04 section 4.8.
% ============================================================

.include "fmma_protocol.inc"

% ---------- one-time initialisation ----------
INIT:
XOR  R0, R0
LDI  R1, #1
LDI  R2, #TICK_SEQ
LDI  R3, #HEARTBEAT

XOR  R11, R11
XOR  R12, R12

LDI  R4, #CFG_POSITION
LOAD R13, R4                % adopt the host's view of the inventory
LDI  R4, #FILL_SEQ
LOAD R14, R4                % do not re-apply an already reported fill

XOR  R7, R7
LDI  R4, #SIGNAL
STOR R7, R4
LDI  R4, #SIGNAL_TICK
STOR R7, R4
LDI  R4, #SIGNAL_SEQ
STOR R7, R4
LDI  R4, #REJECTS
STOR R7, R4
LDI  R4, #QUOTE_BID
STOR R7, R4
LDI  R4, #QUOTE_ASK
STOR R7, R4
LDI  R4, #POSITION
STOR R13, R4

LDI  R7, #STATUS_RUNNING
LDI  R4, #STATUS
STOR R7, R4

% ---------- prove the bitstream implements this ISA ----------
% Two separate 2026 fixes are load-bearing here: the immediate
% operand order, and the rebuilt shifter this strategy uses to
% halve the quotes.  Check both before declaring a version; an
% older bitstream gets no FW_VERSION and the loader refuses to
% trade rather than quoting nonsense.
% ISA_MISMATCH is at the far end of the program, well past the
% +/-127 word reach of a branch, so each check jumps through a
% register instead of branching to it directly.
LDI  R8, #10
SUB  R8, #3                 % must be 7
LDI  R7, #7
CMP  R8, R7
BEQ  PROBE_SHIFT
LDI  R4, #ISA_MISMATCH
JUC  R4

PROBE_SHIFT:
LDI  R8, #64
LSH  R8, #0x1F              % shift right by one: must be 32
LDI  R7, #32
CMP  R8, R7
BEQ  PROBE_OK
LDI  R4, #ISA_MISMATCH
JUC  R4

PROBE_OK:

LDI  R7, #PROTOCOL_VERSION
LDI  R4, #FW_VERSION
STOR R7, R4

LDI  R15, #LOOP

% ============================================================
% Main loop
% ============================================================
LOOP:
ADD  R12, R1
STOR R12, R3

% ---------- restart request ----------
LDI  R4, #CFG_RESTART
LOAD R8, R4
CMP  R8, R0
BNE  DO_RESTART

% ---------- fills ----------
ADD  R4, R1                 % R4 = &FILL_SEQ
LOAD R8, R4
CMP  R8, R14
BEQ  NOFILL
MOV  R14, R8
LDI  R4, #FILL_SIDE
LOAD R8, R4
LDI  R4, #FILL_QTY
LOAD R4, R4
CMP  R8, R1
BNE  FILL_WAS_SOLD
ADD  R13, R4
BUC  FILL_DONE
FILL_WAS_SOLD:
SUB  R13, R4
FILL_DONE:
LDI  R4, #POSITION
STOR R13, R4
NOFILL:

% ---------- new quote? ----------
LOAD R7, R2
CMP  R7, R11
BEQ  LOOP

% ---------- seqlock snapshot ----------
MOV  R8, R7
AND  R8, R1
CMP  R8, R0
BNE  LOOP

MOV  R4, R2
ADD  R4, R1                 % &BID
LOAD R5, R4
ADD  R4, R1                 % &ASK
LOAD R6, R4

LOAD R8, R2
CMP  R8, R7
BNE  LOOP                   % torn: try again next pass

MOV  R11, R7

% ---------- both sides of the book required ----------
CMP  R5, R0
BEQ  LOOP
CMP  R6, R0
BEQ  LOOP

% ============================================================
% Would the market trade against the quotes we are already showing?
% ============================================================
% This has to be checked BEFORE the quotes are recomputed, against
% the prices from the previous tick.  Quotes derived from the
% current mid sit inside the current spread by construction, so a
% quote can only ever be reached by a LATER market move - which is
% exactly how a resting order behaves.  Checking against quotes
% computed from the same tick would mean never trading at all.
%
% R9 = 0 means we have not quoted yet (first tick after a restart).
CMP  R9, R0
BEQ  SET_QUOTES

MOV  R7, R5
ADD  R7, R7                 % R7 = 2 * market bid
CMP  R7, R10
BGE  DO_SELL                % the market bid reached our ask: lifted

MOV  R7, R6
ADD  R7, R7                 % R7 = 2 * market ask
CMP  R9, R7
BGE  DO_BUY                 % the market ask reached our bid: hit

% ============================================================
% Quote construction
% ============================================================
SET_QUOTES:
% R9 = mid2 = bid + ask
MOV  R9, R5
ADD  R9, R6
MOV  R10, R9                % R10 will become the ask side

% R7 = skew2 = 2 * position * CFG_SKEW
LDI  R4, #CFG_SKEW
LOAD R7, R4
MUL  R7, R13                % position may be negative; the low 32
ADD  R7, R7                 % bits of a two's complement product are
                            % still correct, and doubling keeps the
                            % x2 convention

% R8 = 2 * CFG_HALF_SPREAD
LDI  R4, #CFG_HALF_SPREAD
LOAD R8, R4
ADD  R8, R8

% our bid  = mid2 - half - skew
SUB  R9, R8
SUB  R9, R7
% our ask  = mid2 + half - skew
ADD  R10, R8
SUB  R10, R7

% ---------- publish the quotes (halved) ----------
MOV  R7, R9
LSH  R7, #0x1F              % >> 1
LDI  R4, #QUOTE_BID
STOR R7, R4
MOV  R7, R10
LSH  R7, #0x1F
LDI  R4, #QUOTE_ASK
STOR R7, R4

% Quotes refreshed; wait for the next tick.  A tick that trades
% skips this and leaves the quotes in place until the next one,
% which is what a real desk does too: you re-quote after the fill
% is known, not before.
JUC  R15

% ============================================================
% Decisions
% ============================================================
DO_BUY:
LDI  R4, #CFG_ENABLE
LOAD R8, R4
CMP  R8, R0
BEQ  DISABLED_BLOCK
LDI  R4, #CFG_MAX_POS
LOAD R8, R4
CMP  R13, R8
BLT  BUY_ALLOWED
BUC  RISK_BLOCK
BUY_ALLOWED:
LDI  R7, #SIGNAL_BUY
BUC  EMIT

DO_SELL:
LDI  R4, #CFG_ENABLE
LOAD R8, R4
CMP  R8, R0
BEQ  DISABLED_BLOCK
LDI  R4, #CFG_MAX_POS
LOAD R8, R4
XOR  R7, R7
SUB  R7, R8                 % R7 = -MAX_POS
CMP  R7, R13
BLT  SELL_ALLOWED
BUC  RISK_BLOCK
SELL_ALLOWED:
LDI  R7, #SIGNAL_SELL
BUC  EMIT

EMIT:
LDI  R4, #SIGNAL
STOR R7, R4
LDI  R4, #SIGNAL_TICK
STOR R11, R4
LDI  R7, #STATUS_RUNNING
LDI  R4, #STATUS
STOR R7, R4
LDI  R4, #SIGNAL_SEQ        % published last
LOAD R8, R4
ADD  R8, R1
STOR R8, R4
JUC  R15

RISK_BLOCK:
LDI  R7, #STATUS_RISK_BLOCKED
BUC  COUNT_REJECT

DISABLED_BLOCK:
LDI  R7, #STATUS_DISABLED

COUNT_REJECT:
ADD  R7, R1                 % + STATUS_RUNNING
LDI  R4, #STATUS
STOR R7, R4
LDI  R4, #REJECTS
LOAD R8, R4
ADD  R8, R1
STOR R8, R4
JUC  R15

DO_RESTART:
XOR  R8, R8
STOR R8, R4                 % R4 still points at CFG_RESTART
LDI  R4, #INIT
JUC  R4

% ---------- datapath mismatch ----------
ISA_MISMATCH:
ADD  R12, R1
STOR R12, R3
LDI  R4, #ISA_MISMATCH
JUC  R4
