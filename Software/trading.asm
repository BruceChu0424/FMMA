% ============================================================
% FMMA - FPGA Market Maker Accelerator
% trading.asm - market making decision loop
%
% Runs on the custom 32-bit RISC CPU in the FPGA fabric.
% The HPS Linux program loads this at word address 8
% (FPGA_PROGRAM_BASE, see Documents/PROTOCOL.md) and then
% streams market data into the shared RAM:
%
%   word 64: BUY_PRICE   (price * 10000, written by HPS)
%   word 65: SELL_PRICE  (price * 10000, written by HPS)
%   word 66: SIGNAL      (1 = buy, 2 = sell, written by CPU,
%                         cleared by the HPS after it acts)
%   word 67: HEARTBEAT   (loop counter, written by CPU -
%                         lets the HPS verify the CPU is alive)
%
% Strategy (all in price*10000 integer units):
%   1. wait until both prices are non-zero
%   2. crossed market:  buy < sell          -> SIGNAL 1 (buy the bid,
%                                                offer into the ask)
%   3. mean reversion vs. the previous tick:
%        buy  < last_buy  - THRESH          -> SIGNAL 1 (price dipped)
%        sell > last_sell + THRESH          -> SIGNAL 2 (price spiked)
%   4. remember the current prices and repeat forever
%
% Register map:
%   R0  = 0 (constant, never written by the program)
%   R1  = BUY_PRICE word address   (64)
%   R2  = SELL_PRICE word address  (65)
%   R3  = SIGNAL word address      (66)
%   R4  = latest buy price
%   R5  = latest sell price
%   R6  = signal value scratch
%   R7  = 1 (constant)
%   R8  = THRESH (100000 = $10.00 at the x10000 scale)
%   R9  = last buy price (anchor)
%   R10 = last sell price (anchor)
%   R11 = scratch
%   R12 = HEARTBEAT word address   (67)
%   R13 = heartbeat counter
%   R15 = LOOP absolute address (for JUC)
% ============================================================

% ---------- one-time initialisation ----------
XOR R1, R1
OR  R1, #64            % R1 = &BUY_PRICE
XOR R2, R2
OR  R2, #65            % R2 = &SELL_PRICE
XOR R3, R3
OR  R3, #66            % R3 = &SIGNAL
XOR R7, R7
OR  R7, #1             % R7 = 1
XOR R8, R8
OR  R8, #100000        % R8 = THRESH ($10.00)
XOR R12, R12
OR  R12, #67           % R12 = &HEARTBEAT
XOR R13, R13           % heartbeat = 0
OR  R15, #LOOP         % R15 = LOOP (absolute word address)

% ---------- main loop ----------
LOOP:
LOAD R4, R1            % R4 = BUY_PRICE
LOAD R5, R2            % R5 = SELL_PRICE
ADD R13, R7            % heartbeat++
STOR R13, R12

CMP R4, R0             % wait until we have data on both sides
BEQ LOOP
CMP R5, R0
BEQ LOOP

CMP R4, R5             % crossed market: buy < sell
BGT SIG_BUY            % (BGT is taken when N=1, i.e. R4 < R5)

CMP R9, R0             % mean reversion needs an anchor from the
BEQ UPD                % previous iteration

MOV R11, R9            % R11 = last_buy - THRESH
SUB R11, R8
CMP R4, R11            % buy < last_buy - THRESH -> price dipped
BGT SIG_BUY

MOV R11, R10           % R11 = last_sell + THRESH
ADD R11, R8
CMP R11, R5            % last_sell + THRESH < sell -> price spiked
BGT SIG_SELL

UPD:
MOV R9, R4             % remember this tick as the new anchor
MOV R10, R5
JUC R15                % next iteration

SIG_BUY:
XOR R6, R6
OR  R6, #1
STOR R6, R3            % SIGNAL = 1 (buy)
BUC UPD

SIG_SELL:
XOR R6, R6
OR  R6, #2
STOR R6, R3            % SIGNAL = 2 (sell)
BUC UPD
