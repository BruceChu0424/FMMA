#!/usr/bin/env python3
"""Behavioural tests for the CPU trading programs.

These run the real assembled program on the instruction set simulator and
drive it exactly the way the HPS program does: publish a tick through the
seqlock, watch SIGNAL_SEQ for an edge, report fills back.  The same scenarios
run against the RTL in ``Testbenches/tb_strategy.v``; this suite is the fast
one that covers the whole decision table, the RTL one is the slow sanity check
that the hardware agrees.

Run with:
    python test_strategy.py
    python -m unittest test_strategy
"""

import unittest
from pathlib import Path

import protocol as P
import fmma_sim as sim
from Assembler import assemble_file

HERE = Path(__file__).resolve().parent


def build(source):
    _symbols, code, _items = assemble_file(HERE / source, P.PROGRAM_BASE)
    return code


class Board:
    """The CPU plus the HPS-side half of the protocol.

    Everything the HPS program does to the shared RAM is done here too, in the
    same order, so a bug in the handshake shows up in both places.
    """

    def __init__(self, source="trading.asm", thresh=1000, max_pos=3, enable=1,
                 half_spread=0, skew=0, position=0):
        self.cpu = sim.Cpu(pc=P.PROGRAM_BASE)
        self.cpu.load_program(build(source), P.PROGRAM_BASE)
        self.tick = 0
        self.fill_seq = 0
        self.seen_signal_seq = 0
        self.w(P.CFG_THRESH, thresh)
        self.w(P.CFG_MAX_POS, max_pos)
        self.w(P.CFG_ENABLE, enable)
        self.w(P.CFG_HALF_SPREAD, half_spread)
        self.w(P.CFG_SKEW, skew)
        self.w(P.CFG_POSITION, position & 0xFFFFFFFF)
        # Let the initialisation sequence finish.
        self.run(300)

    # -- raw access ---------------------------------------------------------

    def w(self, name_or_index, value):
        self.cpu.write(_idx(name_or_index), value)

    def r(self, name_or_index):
        return self.cpu.read(_idx(name_or_index))

    def signed(self, name_or_index):
        v = self.r(name_or_index)
        return v - (1 << 32) if v & 0x80000000 else v

    def run(self, instructions=2000):
        self.cpu.run(instructions, max_halt_polls=50)

    # -- the HPS side of the protocol ---------------------------------------

    def publish(self, bid, ask, bid_size=10000, ask_size=10000, run=3000):
        """Publish one market-data tick through the seqlock."""
        self.tick += 1
        self.w(P.TICK_SEQ, self.tick * 2 - 1)      # odd: update in progress
        self.w(P.BID, bid)
        self.w(P.ASK, ask)
        self.w(P.BID_SIZE, bid_size)
        self.w(P.ASK_SIZE, ask_size)
        self.w(P.TICK_SEQ, self.tick * 2)          # even: snapshot is stable
        self.run(run)

    def report_fill(self, side, qty, run=3000):
        self.w(P.FILL_SIDE, side)
        self.w(P.FILL_QTY, qty)
        self.fill_seq += 1
        self.w(P.FILL_SEQ, self.fill_seq)
        self.run(run)

    def take_signal(self):
        """Return ``(side, tick)`` if the CPU published a new signal, else None."""
        seq = self.r(P.SIGNAL_SEQ)
        if seq == self.seen_signal_seq:
            return None
        self.seen_signal_seq = seq
        return self.r(P.SIGNAL), self.r(P.SIGNAL_TICK)


def _idx(name_or_index):
    if isinstance(name_or_index, int):
        return name_or_index
    return _WORDS[name_or_index]


_WORDS = {w.name: w.index for w in P.ALL_WORDS}
# Let the tests say Board.w(P.BID, ...) using the module-level names.
for _w in P.ALL_WORDS:
    setattr(P, _w.name, _w.index)


# ---------------------------------------------------------------------------

class TestStartup(unittest.TestCase):

    def test_cpu_waits_for_a_program(self):
        cpu = sim.Cpu(pc=P.PROGRAM_BASE)
        with self.assertRaises(sim.HaltForever):
            cpu.run(10, max_halt_polls=20)
        self.assertEqual(cpu.pc, P.PROGRAM_BASE)

    def test_publishes_its_version_and_status(self):
        b = Board()
        self.assertEqual(b.r(P.FW_VERSION), P.PROTOCOL_VERSION)
        self.assertEqual(b.r(P.STATUS), P.STATUS_RUNNING)

    def test_outputs_start_clear(self):
        b = Board()
        for name in ("SIGNAL", "SIGNAL_TICK", "SIGNAL_SEQ", "POSITION", "REJECTS"):
            self.assertEqual(b.r(name), 0, name)

    def test_heartbeat_advances_while_idle(self):
        b = Board()
        first = b.r(P.HEARTBEAT)
        b.run(500)
        self.assertGreater(b.r(P.HEARTBEAT), first)


class TestSoftwareRestart(unittest.TestCase):
    """CFG_RESTART is the only way the HPS can restart the CPU.

    There is no reset line from the HPS into the fabric, so a loader that
    rewrites the program has to ask the running program to re-enter its own
    initialisation block.
    """

    def test_restart_clears_the_request(self):
        b = Board()
        b.w(P.CFG_RESTART, 1)
        b.run(400)
        self.assertEqual(b.r(P.CFG_RESTART), 0)

    def test_restart_clears_outputs_and_state(self):
        b = Board(thresh=1000, max_pos=100)
        b.report_fill(P.FILL_BOUGHT, 4)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        self.assertIsNotNone(b.take_signal())
        self.assertEqual(b.signed(P.POSITION), 4)

        b.w(P.CFG_RESTART, 1)
        b.run(600)
        self.assertEqual(b.signed(P.POSITION), 0, "inventory survived a restart")
        self.assertEqual(b.r(P.SIGNAL), 0)
        self.assertEqual(b.r(P.SIGNAL_SEQ), 0)
        self.assertEqual(b.r(P.REJECTS), 0)
        self.assertEqual(b.r(P.FW_VERSION), P.PROTOCOL_VERSION)

    def test_restart_does_not_loop(self):
        b = Board()
        b.w(P.CFG_RESTART, 1)
        b.run(400)
        beat = b.r(P.HEARTBEAT)
        b.run(400)
        self.assertGreater(b.r(P.HEARTBEAT), beat,
                           "the CPU is stuck restarting itself")

    def test_strategy_works_again_after_a_restart(self):
        b = Board(thresh=1000, max_pos=100)
        b.w(P.CFG_RESTART, 1)
        b.run(600)
        b.seen_signal_seq = 0
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        sig = b.take_signal()
        self.assertIsNotNone(sig)
        self.assertEqual(sig[0], P.SIGNAL_BUY)

    def test_inventory_is_adopted_from_the_hps_not_zeroed(self):
        b = Board(thresh=1000, max_pos=2)
        b.w(P.CFG_POSITION, 2)             # the broker says we are long 2
        b.w(P.CFG_RESTART, 1)
        b.run(600)
        self.assertEqual(b.signed(P.POSITION), 2)
        # ...and the risk limit must respect it immediately.
        b.seen_signal_seq = b.r(P.SIGNAL_SEQ)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)      # would be a BUY
        self.assertIsNone(b.take_signal(),
                          "restart forgot a real position and allowed a doubling up")

    def test_negative_starting_inventory_is_adopted(self):
        b = Board(thresh=1000, max_pos=2)
        b.w(P.CFG_POSITION, (-2) & 0xFFFFFFFF)
        b.w(P.CFG_RESTART, 1)
        b.run(600)
        self.assertEqual(b.signed(P.POSITION), -2)

    def test_a_reloaded_program_restarts_from_a_clean_state(self):
        b = Board(thresh=1000, max_pos=100)
        b.report_fill(P.FILL_BOUGHT, 7)
        self.assertEqual(b.signed(P.POSITION), 7)
        # What the loader does: rewrite the image, then ask for a restart.
        b.cpu.load_program(build("trading.asm"), P.PROGRAM_BASE)
        b.w(P.CFG_RESTART, 1)
        b.run(600)
        self.assertEqual(b.signed(P.POSITION), 0)
        self.assertEqual(b.r(P.FW_VERSION), P.PROTOCOL_VERSION)


class TestDecisions(unittest.TestCase):

    def test_first_tick_only_anchors(self):
        b = Board()
        b.publish(10_000_00, 10_001_00)
        self.assertIsNone(b.take_signal())

    def test_small_move_does_not_signal(self):
        b = Board(thresh=1000)                     # $10.00
        b.publish(10_000_00, 10_001_00)
        b.publish(9_999_00, 10_000_00)             # mid moved $1
        self.assertIsNone(b.take_signal())

    def test_fall_through_the_band_signals_buy(self):
        b = Board(thresh=1000)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)              # mid fell $20
        sig = b.take_signal()
        self.assertIsNotNone(sig)
        self.assertEqual(sig[0], P.SIGNAL_BUY)

    def test_rise_through_the_band_signals_sell(self):
        b = Board(thresh=1000)
        b.publish(10_000_00, 10_001_00)
        b.publish(10_020_00, 10_021_00)            # mid rose $20
        sig = b.take_signal()
        self.assertIsNotNone(sig)
        self.assertEqual(sig[0], P.SIGNAL_SELL)

    def test_signal_carries_the_tick_that_caused_it(self):
        b = Board(thresh=1000)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        side, tick = b.take_signal()
        self.assertEqual(tick, b.r(P.TICK_SEQ))

    def test_decision_re_anchors_so_one_move_fires_once(self):
        b = Board(thresh=1000)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        self.assertIsNotNone(b.take_signal())
        b.publish(9_980_00, 9_981_00)              # same level again
        self.assertIsNone(b.take_signal())

    def test_a_staircase_fires_on_each_step(self):
        b = Board(thresh=1000, max_pos=100)
        b.publish(10_000_00, 10_001_00)
        sides = []
        for step in range(1, 5):
            b.publish(10_000_00 - step * 2100, 10_001_00 - step * 2100)
            sig = b.take_signal()
            if sig:
                sides.append(sig[0])
        self.assertEqual(sides, [P.SIGNAL_BUY] * 4)

    def test_one_sided_book_is_ignored(self):
        b = Board(thresh=1000)
        b.publish(10_000_00, 10_001_00)
        b.publish(0, 9_981_00)                     # no bid
        self.assertIsNone(b.take_signal())
        b.publish(9_980_00, 0)                     # no ask
        self.assertIsNone(b.take_signal())


class TestSeqlock(unittest.TestCase):

    def test_odd_tick_seq_is_not_consumed(self):
        b = Board(thresh=1000)
        b.publish(10_000_00, 10_001_00)
        # The HPS starts an update and stops half way: seq is odd.
        b.w(P.TICK_SEQ, b.r(P.TICK_SEQ) + 1)
        b.w(P.BID, 9_980_00)
        b.run(3000)
        self.assertIsNone(b.take_signal(),
                          "the CPU acted on a snapshot that was still being written")

    def test_torn_snapshot_is_retried_not_used(self):
        """A write that lands between the CPU's two TICK_SEQ reads is detected.

        The discriminator is SIGNAL_TICK.  Tick 4 carries a quiet market that
        would produce no signal; while the CPU is half way through reading it,
        tick 6 arrives with a large move.  Reading tick 4's BID together with
        tick 6's ASK also produces a signal, so the presence of a signal proves
        nothing - but a torn read commits the *old* sequence number, while a
        correct seqlock retry commits the new one.
        """
        b = Board(thresh=1000, max_pos=100)
        b.publish(10_000_00, 10_001_00)            # anchor, tick seq 2

        old_seq, new_seq = 4, 6
        state = {"armed": True}

        def meddle(cpu, decoded):
            # Fire right after 'LOAD R5, R4', the instruction that reads BID.
            if state["armed"] and decoded.kind == "load" and decoded.rd == 5:
                state["armed"] = False
                cpu.write(_idx("TICK_SEQ"), new_seq - 1)     # odd: writing
                cpu.write(_idx("ASK"), 12_000_00)            # a huge move
                cpu.write(_idx("TICK_SEQ"), new_seq)         # even: published

        # Publish the quiet tick 4 and let the CPU start reading it.
        b.w(P.BID, 10_000_00)
        b.w(P.ASK, 10_001_00)
        b.w(P.TICK_SEQ, old_seq)
        b.cpu.run(6000, max_halt_polls=50, on_step=meddle)

        self.assertFalse(state["armed"], "the meddling never fired; test is broken")
        sig = b.take_signal()
        self.assertIsNotNone(sig, "expected the retry to pick up tick 6")
        self.assertEqual(sig[1], new_seq,
                         "the CPU committed a snapshot that was torn across ticks")

    def test_repeated_tick_is_processed_once(self):
        b = Board(thresh=1000, max_pos=100)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        self.assertIsNotNone(b.take_signal())
        seq_after = b.r(P.SIGNAL_SEQ)
        b.run(5000)                                 # no new tick published
        self.assertEqual(b.r(P.SIGNAL_SEQ), seq_after,
                         "the CPU re-signalled without a new tick")


class TestRiskLimits(unittest.TestCase):

    def test_buy_blocked_at_the_long_limit(self):
        b = Board(thresh=1000, max_pos=2)
        b.report_fill(P.FILL_BOUGHT, 2)             # position = +2 = the limit
        self.assertEqual(b.signed(P.POSITION), 2)
        b.publish(10_000_00, 10_001_00)
        rejects = b.r(P.REJECTS)
        b.publish(9_980_00, 9_981_00)               # would be a BUY
        self.assertIsNone(b.take_signal())
        self.assertEqual(b.r(P.REJECTS), rejects + 1)
        self.assertTrue(b.r(P.STATUS) & P.STATUS_RISK_BLOCKED)

    def test_sell_blocked_at_the_short_limit(self):
        b = Board(thresh=1000, max_pos=2)
        b.report_fill(P.FILL_SOLD, 2)               # position = -2
        self.assertEqual(b.signed(P.POSITION), -2)
        b.publish(10_000_00, 10_001_00)
        rejects = b.r(P.REJECTS)
        b.publish(10_020_00, 10_021_00)             # would be a SELL
        self.assertIsNone(b.take_signal())
        self.assertEqual(b.r(P.REJECTS), rejects + 1)

    def test_selling_is_still_allowed_while_long(self):
        b = Board(thresh=1000, max_pos=2)
        b.report_fill(P.FILL_BOUGHT, 2)
        b.publish(10_000_00, 10_001_00)
        b.publish(10_020_00, 10_021_00)             # a SELL reduces the position
        sig = b.take_signal()
        self.assertIsNotNone(sig)
        self.assertEqual(sig[0], P.SIGNAL_SELL)

    def test_buying_is_still_allowed_while_short(self):
        b = Board(thresh=1000, max_pos=2)
        b.report_fill(P.FILL_SOLD, 2)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        sig = b.take_signal()
        self.assertIsNotNone(sig)
        self.assertEqual(sig[0], P.SIGNAL_BUY)

    def test_just_inside_the_limit_is_allowed(self):
        b = Board(thresh=1000, max_pos=3)
        b.report_fill(P.FILL_BOUGHT, 2)             # +2 < +3
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        self.assertIsNotNone(b.take_signal())

    def test_disable_switch_suppresses_everything(self):
        b = Board(thresh=1000, enable=0)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        self.assertIsNone(b.take_signal())
        self.assertEqual(b.r(P.REJECTS), 1)
        self.assertTrue(b.r(P.STATUS) & P.STATUS_DISABLED)

    def test_re_enabling_resumes_trading(self):
        b = Board(thresh=1000, enable=0)
        b.publish(10_000_00, 10_001_00)
        b.publish(9_980_00, 9_981_00)
        self.assertIsNone(b.take_signal())
        b.w(P.CFG_ENABLE, 1)
        b.publish(9_950_00, 9_951_00)
        self.assertIsNotNone(b.take_signal())
        self.assertFalse(b.r(P.STATUS) & P.STATUS_DISABLED)


class TestFillAccounting(unittest.TestCase):

    def test_buys_and_sells_move_the_position(self):
        b = Board(max_pos=100)
        b.report_fill(P.FILL_BOUGHT, 5)
        self.assertEqual(b.signed(P.POSITION), 5)
        b.report_fill(P.FILL_SOLD, 2)
        self.assertEqual(b.signed(P.POSITION), 3)
        b.report_fill(P.FILL_SOLD, 8)
        self.assertEqual(b.signed(P.POSITION), -5)

    def test_a_fill_is_applied_once(self):
        b = Board(max_pos=100)
        b.report_fill(P.FILL_BOUGHT, 4)
        b.run(5000)                                 # no new FILL_SEQ
        self.assertEqual(b.signed(P.POSITION), 4)

    def test_position_survives_many_ticks(self):
        b = Board(thresh=1000, max_pos=100)
        b.report_fill(P.FILL_BOUGHT, 3)
        for i in range(6):
            b.publish(10_000_00 + i * 100, 10_001_00 + i * 100)
        self.assertEqual(b.signed(P.POSITION), 3)


class TestTiming(unittest.TestCase):

    def test_idle_loop_cost(self):
        b = Board()
        cpu = b.cpu
        # Align to the top of the loop, then time 100 iterations.
        beat = cpu.read(_idx("HEARTBEAT"))
        while cpu.read(_idx("HEARTBEAT")) == beat:
            cpu.step()
        start = cpu.cycles
        beat = cpu.read(_idx("HEARTBEAT"))
        for _ in range(100):
            while cpu.read(_idx("HEARTBEAT")) == beat:
                cpu.step()
            beat = cpu.read(_idx("HEARTBEAT"))
        per_loop = (cpu.cycles - start) / 100
        # 13 instructions x 3 cycles: heartbeat store, restart check,
        # fill check, tick check.  780 ns, so a freshly published quote
        # is picked up within that.  If this number changes,
        # docs/14-latency-and-performance.md needs updating with it.
        self.assertEqual(per_loop, 39.0)

    def test_decision_latency_is_bounded(self):
        b = Board(thresh=1000, max_pos=100)
        b.publish(10_000_00, 10_001_00)
        cpu = b.cpu
        before = cpu.cycles
        seq = cpu.read(_idx("SIGNAL_SEQ"))
        # publish by hand so no instructions run in between
        b.tick += 1
        b.w(P.TICK_SEQ, b.tick * 2 - 1)
        b.w(P.BID, 9_980_00)
        b.w(P.ASK, 9_981_00)
        b.w(P.TICK_SEQ, b.tick * 2)
        cpu.run_until(lambda c: c.read(_idx("SIGNAL_SEQ")) != seq)
        cycles = cpu.cycles - before
        self.assertLess(cycles, 250, f"decision took {cycles} cycles")


if __name__ == "__main__":
    unittest.main(verbosity=2)


class TestMarketMaker(unittest.TestCase):
    """Two-sided quoting: market_maker.asm.

    This is the strategy the project is named for. It computes a bid and
    an ask around the mid, leans them against inventory, and signals when
    a LATER market move reaches the price it was showing.
    """

    SRC = "market_maker.asm"

    def mm(self, **kw):
        kw.setdefault("source", self.SRC)
        kw.setdefault("half_spread", 200)      # $2.00
        kw.setdefault("max_pos", 100)
        return Board(**kw)

    def test_publishes_its_version(self):
        b = self.mm()
        self.assertEqual(b.r(P.FW_VERSION), P.PROTOCOL_VERSION,
                         "the datapath probe (SUB and LSH immediates) failed")

    def test_quotes_straddle_the_mid_when_flat(self):
        b = self.mm(half_spread=200, skew=0)
        b.publish(10_000_00, 10_002_00)        # mid = 1000100
        self.assertEqual(b.r(P.QUOTE_BID), 1000100 - 200)
        self.assertEqual(b.r(P.QUOTE_ASK), 1000100 + 200)

    def test_first_tick_only_quotes(self):
        b = self.mm()
        b.publish(10_000_00, 10_002_00)
        self.assertIsNone(b.take_signal(),
                          "nothing to trade against on the first tick")

    def test_no_signal_while_the_market_stays_inside_our_quotes(self):
        b = self.mm(half_spread=500)
        b.publish(10_000_00, 10_002_00)
        b.publish(10_000_50, 10_002_50)        # a 50-cent drift
        self.assertIsNone(b.take_signal())

    def test_a_rise_lifts_our_ask(self):
        b = self.mm(half_spread=200)
        b.publish(10_000_00, 10_002_00)        # quote 1000100 +/- 200
        b.publish(10_010_00, 10_012_00)        # market bid now above our ask
        sig = b.take_signal()
        self.assertIsNotNone(sig)
        self.assertEqual(sig[0], P.SIGNAL_SELL)

    def test_a_fall_hits_our_bid(self):
        b = self.mm(half_spread=200)
        b.publish(10_000_00, 10_002_00)
        b.publish(9_990_00, 9_992_00)          # market ask now below our bid
        sig = b.take_signal()
        self.assertIsNotNone(sig)
        self.assertEqual(sig[0], P.SIGNAL_BUY)

    def test_a_wider_spread_trades_less(self):
        tight = self.mm(half_spread=50)
        tight.publish(10_000_00, 10_002_00)
        tight.publish(10_003_00, 10_005_00)
        self.assertIsNotNone(tight.take_signal(), "a tight quote is reached")

        wide = self.mm(half_spread=5000)       # $50 each side
        wide.publish(10_000_00, 10_002_00)
        wide.publish(10_003_00, 10_005_00)
        self.assertIsNone(wide.take_signal(), "a wide quote is not")

    def test_long_inventory_skews_both_quotes_down(self):
        flat = self.mm(half_spread=200, skew=50, position=0)
        flat.publish(10_000_00, 10_002_00)
        bid0, ask0 = flat.r(P.QUOTE_BID), flat.r(P.QUOTE_ASK)

        long_ = self.mm(half_spread=200, skew=50, position=4)
        long_.publish(10_000_00, 10_002_00)
        self.assertEqual(long_.signed(P.POSITION), 4, "inventory adopted")
        self.assertEqual(bid0 - long_.r(P.QUOTE_BID), 200, "bid skewed down")
        self.assertEqual(ask0 - long_.r(P.QUOTE_ASK), 200, "ask skewed down")

    def test_short_inventory_skews_both_quotes_up(self):
        flat = self.mm(half_spread=200, skew=50, position=0)
        flat.publish(10_000_00, 10_002_00)
        bid0 = flat.r(P.QUOTE_BID)

        short = self.mm(half_spread=200, skew=50,
                        position=(-4) & 0xFFFFFFFF)
        short.publish(10_000_00, 10_002_00)
        self.assertEqual(short.signed(P.POSITION), -4)
        self.assertEqual(short.r(P.QUOTE_BID) - bid0, 200, "bid skewed up")

    def test_skew_makes_the_reducing_side_easier_to_reach(self):
        """The point of the skew: when long, a rise trades sooner."""
        # Quotes come from tick 1: mid2 = 2_000_200, half-spread 200.
        #   flat  ask2 = 2_000_600  -> needs the bid at 1_000_300
        #   long  ask2 = 1_999_800  -> needs the bid at   999_900
        # A tick-2 bid of 1_000_100 falls between the two.
        flat = self.mm(half_spread=200, skew=100, position=0)
        flat.publish(10_000_00, 10_002_00)
        flat.publish(10_001_00, 10_003_00)

        long_ = self.mm(half_spread=200, skew=100, position=4)
        long_.publish(10_000_00, 10_002_00)
        long_.publish(10_001_00, 10_003_00)

        self.assertIsNone(flat.take_signal(), "flat: the move is too small")
        sig = long_.take_signal()
        self.assertIsNotNone(sig, "long: the skew brought the ask within reach")
        self.assertEqual(sig[0], P.SIGNAL_SELL)

    def test_risk_limit_blocks_a_buy_at_the_long_limit(self):
        b = self.mm(half_spread=200, max_pos=2, position=2)
        b.publish(10_000_00, 10_002_00)
        rejects = b.r(P.REJECTS)
        b.publish(9_990_00, 9_992_00)          # would hit our bid -> BUY
        self.assertIsNone(b.take_signal())
        self.assertEqual(b.r(P.REJECTS), rejects + 1)
        self.assertTrue(b.r(P.STATUS) & P.STATUS_RISK_BLOCKED)

    def test_disable_switch_suppresses_quoting_signals(self):
        b = self.mm(half_spread=200, enable=0)
        b.publish(10_000_00, 10_002_00)
        b.publish(10_010_00, 10_012_00)
        self.assertIsNone(b.take_signal())
        self.assertGreater(b.r(P.REJECTS), 0)
        self.assertTrue(b.r(P.STATUS) & P.STATUS_DISABLED)

    def test_fills_move_the_inventory(self):
        b = self.mm(max_pos=100)
        b.report_fill(P.FILL_BOUGHT, 3)
        self.assertEqual(b.signed(P.POSITION), 3)
        b.report_fill(P.FILL_SOLD, 5)
        self.assertEqual(b.signed(P.POSITION), -2)

    def test_heartbeat_runs(self):
        b = self.mm()
        first = b.r(P.HEARTBEAT)
        b.run(600)
        self.assertGreater(b.r(P.HEARTBEAT), first)
