% ============================================================
% FMMA - isa_probe.asm
%
% An ISA conformance program for the fabric.
%
% The strategies carry a short datapath probe that refuses to publish
% FW_VERSION if the bitstream predates the 2026 datapath fixes.  That
% is the right behaviour in production and a poor diagnostic: it
% reports one bit - "something is wrong" - and then spins.  When
% market_maker.asm failed that probe on real hardware while
% trading.asm passed, the question "which instruction does this
% bitstream get wrong?" had no cheap answer.
%
% This program answers it.  Each feature is checked independently and
% contributes one bit to a result word; a failing check costs its bit
% and nothing else, so one broken instruction does not hide the state
% of the others.  It cannot wedge: there is no jump that depends on a
% check passing, and the heartbeat runs throughout.
%
%   fmma-probe read 328     bit mask, 1 = that check passed
%   fmma-probe read 329     number of checks, so a partial run is
%                           distinguishable from a passing one
%
% Bits, low to high:
%   0  MOV  immediate            LDI R8,#10      -> 10
%   1  SUB  immediate order      10 - 3          -> 7   (not 3 - 10)
%   2  ADD  immediate            7 + 3           -> 10
%   3  LSH  immediate, left      1 << 4          -> 16
%   4  LSH  immediate, right     64 >> 1         -> 32  (count 0x1F)
%   5  ASH  immediate, right     signed, keeps the sign
%   6  CMP/BEQ taken             equal values branch
%   7  CMP/BNE taken             unequal values branch
%   8  register jump             JUC through a register
%   9  LOAD/STOR round trip      through shared RAM
%
% Load it exactly like a strategy - it uses the same protocol words -
% and read the two output words.  See docs/15-troubleshooting.md.
% ============================================================

.include "fmma_protocol.inc"

.equ CHECK_COUNT, 10

INIT:
XOR  R0, R0                 % zero, whatever a previous program left
LDI  R1, #1
LDI  R3, #HEARTBEAT
% The heartbeat counter is deliberately NOT zeroed here.  INIT runs
% again on every CFG_RESTART, and a counter that restarts from zero
% looks identical to a stopped one from the host, which compares
% successive samples.  It only has to change.
XOR  R10, R10               % result mask, built up one bit at a time
LDI  R11, #1                % the bit currently under test

% Publish "no checks passed yet" immediately, so a program that dies
% part way through is distinguishable from one that never ran.
LDI  R4, #QUOTE_BID
STOR R10, R4
LDI  R7, #0
LDI  R4, #QUOTE_ASK
STOR R7, R4

% ------------------------------------------------------------
% Each check leaves its verdict in R6: 0, or the bit it owns.
%
% The bit position in R11 advances with ADD R11, R11 rather than a
% left shift.  A conformance probe must not depend on the instruction
% it is testing: the first version used LSH here, and when LSH turned
% out to be the broken one the whole mask came back as garbage
% instead of one clear bit.
% ------------------------------------------------------------

% ---- bit 0: MOV immediate ----
XOR  R6, R6
LDI  R8, #10
LDI  R7, #10
CMP  R8, R7
BNE  M0
ADD  R6, R11
M0:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 1: SUB immediate operand order ----
XOR  R6, R6
LDI  R8, #10
SUB  R8, #3
LDI  R7, #7
CMP  R8, R7
BNE  M1
ADD  R6, R11
M1:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 2: ADD immediate ----
XOR  R6, R6
LDI  R8, #7
ADD  R8, #3
LDI  R7, #10
CMP  R8, R7
BNE  M2
ADD  R6, R11
M2:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 3: LSH immediate, shifting left ----
XOR  R6, R6
LDI  R8, #1
LSH  R8, #4
LDI  R7, #16
CMP  R8, R7
BNE  M3
ADD  R6, R11
M3:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 4: LSH immediate, shifting right ----
% A count with bit 4 set means "shift right by the two's complement
% of the low five bits", so 0x1F is a right shift of one.  This is
% the check market_maker.asm fails on hardware.
XOR  R6, R6
LDI  R8, #64
LSH  R8, #0x1F
LDI  R7, #32
CMP  R8, R7
BNE  M4
ADD  R6, R11
M4:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 5: ASH immediate, shifting right, sign preserved ----
% -16 >> 2 must be -4, not a large positive number.
XOR  R6, R6
LDI  R8, #16
XOR  R7, R7
SUB  R7, R8                 % R7 = -16
ASH  R7, #0x1E              % arithmetic right by two
LDI  R8, #4
XOR  R5, R5
SUB  R5, R8                 % R5 = -4
CMP  R7, R5
BNE  M5
ADD  R6, R11
M5:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 6: a taken BEQ ----
XOR  R6, R6
LDI  R8, #5
LDI  R7, #5
CMP  R8, R7
BEQ  M6TAKEN
BUC  M6                     % not taken: leave the bit clear
M6TAKEN:
ADD  R6, R11
M6:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 7: a taken BNE ----
XOR  R6, R6
LDI  R8, #5
LDI  R7, #6
CMP  R8, R7
BNE  M7TAKEN
BUC  M7
M7TAKEN:
ADD  R6, R11
M7:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 8: a jump through a register ----
XOR  R6, R6
LDI  R4, #J8TAKEN
JUC  R4
BUC  M8                     % only reached if the jump did not happen
J8TAKEN:
ADD  R6, R11
M8:
ADD  R10, R6
ADD  R11, R11               % next bit

% ---- bit 9: LOAD/STOR round trip through shared RAM ----
% Uses the free region above the protocol block, so it cannot
% disturb anything the host is reading.
XOR  R6, R6
LDI  R8, #0x5A5
LDI  R4, #512
STOR R8, R4
LOAD R7, R4
CMP  R8, R7
BNE  M9
ADD  R6, R11
M9:
ADD  R10, R6
ADD  R11, R11               % next bit

% ------------------------------------------------------------
% Publish the verdict, then heartbeat forever so the host can see
% the program is alive and did not stop half way.
% ------------------------------------------------------------
LDI  R4, #QUOTE_BID
STOR R10, R4
LDI  R7, #CHECK_COUNT
LDI  R4, #QUOTE_ASK
STOR R7, R4

% FW_VERSION last, as the protocol requires, so the loader accepts it.
LDI  R7, #PROTOCOL_VERSION
LDI  R4, #FW_VERSION
STOR R7, R4

% Publish the bit register too.  If the mask looks wrong, the first
% question is whether the bit machinery itself worked: R11 must end
% at 1 << CHECK_COUNT.
LDI  R4, #QUOTE_BID
ADD  R4, #2                 % QUOTE_BID + 2, still inside the CPU's block
STOR R11, R4

SPIN:
ADD  R12, R1
STOR R12, R3

% Honour CFG_RESTART, exactly as the strategies do.
%
% This is not optional for a program the loader drives.  The loader
% writes the entry word, which starts the CPU immediately, and only
% afterwards zeroes FW_VERSION so a stale value cannot fool it.  A
% program that publishes its version once and then spins loses that
% race every time: it has already finished before the loader clears
% the word, and nothing ever writes it again.  The loader then
% reports "alive but will not declare a version" and the real fault
% is nowhere near where it looks.
LDI  R4, #CFG_RESTART
LOAD R5, R4
XOR  R7, R7
CMP  R5, R7
BEQ  SPIN

% Acknowledge it before restarting, or the next pass sees the same
% request and the probe restarts for ever instead of settling.
XOR  R8, R8
STOR R8, R4
LDI  R4, #INIT
JUC  R4
