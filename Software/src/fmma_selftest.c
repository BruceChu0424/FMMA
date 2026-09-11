#include "fmma_selftest.h"

#include "fmma_fpga.h"

#include "../fmma_protocol.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* Long enough for the CPU to go round its loop many times - the loop is
 * under a microsecond - but short enough that a hung CPU costs little. */
#define SETTLE_US 20000u

/* A price far from any real one, so a stale value is obvious. */
#define BASE_PRICE (50000u * FMMA_PRICE_SCALE)

struct ctx {
    struct fmma_fpga *f;
    struct fmma_selftest_result *r;
    uint32_t step;            /* price movement per quote */
};

/* ------------------------------------------------------------------ */

static void check(struct ctx *c, int ok, const char *what, const char *detail)
{
    c->r->run++;
    if (ok) {
        c->r->passed++;
        printf("  PASS  %s\n", what);
    } else {
        c->r->failed++;
        printf("  FAIL  %s\n", what);
        if (detail && *detail) printf("        %s\n", detail);
    }
}

static void checkf(struct ctx *c, int ok, const char *what,
                   const char *fmt, ...)
{
    char buf[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    check(c, ok, what, ok ? "" : buf);
}

/*
 * Publish one quote and wait for the CPU to have had a chance to act on
 * it.  Returns 1 if a decision came back.
 *
 * Waiting on a fixed delay rather than on the signal counter is
 * deliberate here: several of these checks are about the CPU *not*
 * producing a decision, and "wait until it does" cannot test that.
 */
static int quote_and_settle(struct ctx *c, int direction,
                            struct fmma_signal *sig)
{
    uint32_t step = c->step;
    uint32_t mid = (direction < 0) ? BASE_PRICE - step : BASE_PRICE + step;

    /* Re-anchor at the base, then move, so each call is a clean
     * single move of a known size regardless of what came before. */
    fmma_fpga_publish_tick(c->f, BASE_PRICE - 100, BASE_PRICE + 100, 1, 1);
    usleep(SETTLE_US);
    struct fmma_signal discard;
    fmma_fpga_poll_signal(c->f, &discard);

    fmma_fpga_publish_tick(c->f, mid - 100, mid + 100, 1, 1);
    usleep(SETTLE_US);

    struct fmma_signal local;
    if (!sig) sig = &local;
    memset(sig, 0, sizeof(*sig));
    return fmma_fpga_poll_signal(c->f, sig);
}

/* ------------------------------------------------------------------ */

static void t_liveness(struct ctx *c)
{
    uint32_t v = fmma_fpga_read(c->f, FMMA_FW_VERSION);
    checkf(c, v == FMMA_PROTOCOL_VERSION,
           "the CPU reports the protocol version this host was built for",
           "FW_VERSION reads %u, expected %u", v, FMMA_PROTOCOL_VERSION);

    uint32_t a = fmma_fpga_read(c->f, FMMA_HEARTBEAT);
    usleep(SETTLE_US);
    uint32_t b = fmma_fpga_read(c->f, FMMA_HEARTBEAT);
    checkf(c, b != a, "the heartbeat advances (the CPU is executing)",
           "HEARTBEAT stuck at %u", a);

    uint32_t st = fmma_fpga_read(c->f, FMMA_STATUS);
    checkf(c, (st & FMMA_STATUS_RUNNING) != 0,
           "STATUS reports RUNNING", "STATUS = 0x%X", st);
}

static void t_seqlock_at_rest(struct ctx *c)
{
    /* The host owns TICK_SEQ and only leaves it odd mid-publish, so
     * after any completed publish it must be even.  An odd value here
     * would mean a write was torn or abandoned. */
    fmma_fpga_publish_tick(c->f, BASE_PRICE - 100, BASE_PRICE + 100, 1, 1);
    uint32_t seq = fmma_fpga_read(c->f, FMMA_TICK_SEQ);
    checkf(c, (seq & 1u) == 0,
           "TICK_SEQ is even once a publish completes",
           "TICK_SEQ = %u (odd means a torn write)", seq);
}

static void t_decides(struct ctx *c)
{
    struct fmma_signal sig;
    int got = quote_and_settle(c, -1, &sig);
    checkf(c, got && sig.side == FMMA_SIGNAL_BUY,
           "a downward move past the threshold produces BUY",
           got ? "got side %u" : "no decision at all", sig.side);

    got = quote_and_settle(c, +1, &sig);
    checkf(c, got && sig.side == FMMA_SIGNAL_SELL,
           "an upward move past the threshold produces SELL",
           got ? "got side %u" : "no decision at all", sig.side);
}

static void t_below_threshold(struct ctx *c)
{
    /* A move smaller than the band must produce nothing.  This is the
     * check that catches a threshold that was never applied - which a
     * "does it trade?" test passes happily. */
    uint32_t saved = c->step;
    c->step = 1;                       /* well inside the band */
    struct fmma_signal sig;
    int got = quote_and_settle(c, -1, &sig);
    c->step = saved;

    checkf(c, !got, "a move smaller than the threshold produces nothing",
           "got a decision (side %u) that should have been suppressed",
           sig.side);
}

static void t_kill_switch(struct ctx *c)
{
    uint32_t before = fmma_fpga_read(c->f, FMMA_REJECTS);

    fmma_fpga_set_enabled(c->f, 0);
    usleep(SETTLE_US);

    /* The order matters.  STATUS is written by the CPU on the decision
     * path, so it cannot report the new setting until a quote has been
     * evaluated under it - see docs/07 §7.3.  Checking it before
     * publishing anything tests the host's own write, not the fabric. */
    struct fmma_signal sig;
    int got = quote_and_settle(c, -1, &sig);
    checkf(c, !got, "no decisions are published while disabled",
           "got side %u while CFG_ENABLE was 0", sig.side);

    uint32_t st = fmma_fpga_read(c->f, FMMA_STATUS);
    checkf(c, (st & FMMA_STATUS_DISABLED) != 0,
           "the quote evaluated while disabled sets STATUS_DISABLED",
           "STATUS = 0x%X", st);

    uint32_t after = fmma_fpga_read(c->f, FMMA_REJECTS);
    checkf(c, after > before,
           "a suppressed decision is counted in REJECTS",
           "REJECTS did not move from %u", before);

    /* Disabled must not mean dead: the engine keeps running so the
     * host can see it is alive and can re-enable it. */
    uint32_t h = fmma_fpga_read(c->f, FMMA_HEARTBEAT);
    usleep(SETTLE_US);
    checkf(c, fmma_fpga_read(c->f, FMMA_HEARTBEAT) != h,
           "the heartbeat keeps running while disabled",
           "HEARTBEAT stuck at %u", h);

    fmma_fpga_set_enabled(c->f, 1);
    usleep(SETTLE_US);
    got = quote_and_settle(c, -1, &sig);
    checkf(c, got, "CFG_ENABLE = 1 resumes trading", "still suppressed");
}

/*
 * The property that matters most: the limit is enforced by the fabric,
 * not by the host.  The host here does nothing but report fills
 * truthfully and watch.
 */
static void t_risk_limit(struct ctx *c)
{
    const int32_t limit = 2;

    /* Start flat and set a low limit. */
    fmma_fpga_write(c->f, FMMA_CFG_POSITION, 0);
    fmma_fpga_write(c->f, FMMA_CFG_MAX_POS, (uint32_t)limit);
    fmma_fpga_write(c->f, FMMA_CFG_RESTART,
                    fmma_fpga_read(c->f, FMMA_CFG_RESTART) + 1);
    usleep(SETTLE_US);

    uint32_t rejects_before = fmma_fpga_read(c->f, FMMA_REJECTS);
    int buys = 0;

    /* Drive the position up against the limit, reporting each fill. */
    for (int i = 0; i < limit + 3; i++) {
        struct fmma_signal sig;
        if (quote_and_settle(c, -1, &sig) && sig.side == FMMA_SIGNAL_BUY) {
            buys++;
            fmma_fpga_report_fill(c->f, FMMA_FILL_BOUGHT, 1);
            usleep(SETTLE_US);
        }
    }

    int32_t pos = (int32_t)fmma_fpga_read(c->f, FMMA_POSITION);
    checkf(c, pos == limit,
           "the fabric clamps the position at CFG_MAX_POS",
           "POSITION = %d, expected %d after %d buys", pos, limit, buys);
    checkf(c, buys == limit,
           "buys past the limit are refused, not filled",
           "the fabric issued %d buys with a limit of %d", buys, limit);

    uint32_t rejects_after = fmma_fpga_read(c->f, FMMA_REJECTS);
    checkf(c, rejects_after > rejects_before,
           "refusals at the limit are counted in REJECTS",
           "REJECTS did not move from %u", rejects_before);

    uint32_t st = fmma_fpga_read(c->f, FMMA_STATUS);
    checkf(c, (st & FMMA_STATUS_RISK_BLOCKED) != 0,
           "STATUS reports RISK_BLOCKED at the limit",
           "STATUS = 0x%X", st);

    /* And the part that a naive limit gets wrong: at the limit you may
     * still trade the side that reduces the position. */
    struct fmma_signal sig;
    int got = quote_and_settle(c, +1, &sig);
    checkf(c, got && sig.side == FMMA_SIGNAL_SELL,
           "the reducing side is still allowed at the limit",
           got ? "got side %u" : "the reducing side was blocked too",
           sig.side);

    if (got) {
        fmma_fpga_report_fill(c->f, FMMA_FILL_SOLD, 1);
        usleep(SETTLE_US);
        pos = (int32_t)fmma_fpga_read(c->f, FMMA_POSITION);
        checkf(c, pos == limit - 1,
               "a reported fill moves the fabric's position",
               "POSITION = %d, expected %d", pos, limit - 1);
    }
}

/*
 * Restart must reinitialise from the configuration, not from whatever
 * the previous run left behind.  An early version re-applied stale
 * fills and zeroed the inventory on restart, which is how a restart
 * silently loses a position.
 */
static void t_restart(struct ctx *c)
{
    const int32_t want = -3;

    fmma_fpga_write(c->f, FMMA_CFG_POSITION, (uint32_t)want);
    fmma_fpga_write(c->f, FMMA_CFG_RESTART,
                    fmma_fpga_read(c->f, FMMA_CFG_RESTART) + 1);
    usleep(SETTLE_US);

    int32_t pos = (int32_t)fmma_fpga_read(c->f, FMMA_POSITION);
    checkf(c, pos == want,
           "restart adopts CFG_POSITION, including a short one",
           "POSITION = %d, expected %d", pos, want);

    uint32_t st = fmma_fpga_read(c->f, FMMA_STATUS);
    checkf(c, (st & FMMA_STATUS_RUNNING) != 0,
           "the CPU is still running after a restart",
           "STATUS = 0x%X", st);

    /* Put it back to flat so the caller is not left holding a
     * position invented by a test. */
    fmma_fpga_write(c->f, FMMA_CFG_POSITION, 0);
    fmma_fpga_write(c->f, FMMA_CFG_RESTART,
                    fmma_fpga_read(c->f, FMMA_CFG_RESTART) + 1);
    usleep(SETTLE_US);
}

static void t_host_never_written(struct ctx *c)
{
    /*
     * The protocol says the host writes only the input block.  Nothing
     * enforces that in hardware, so check the one direction that can
     * be checked: the CPU is the only writer of the output block, and
     * it must keep updating it even when the host is quiet.
     */
    uint32_t seq = fmma_fpga_read(c->f, FMMA_SIGNAL_SEQ);
    usleep(SETTLE_US);
    checkf(c, fmma_fpga_read(c->f, FMMA_SIGNAL_SEQ) == seq,
           "SIGNAL_SEQ does not move without a quote",
           "it advanced with no input, so something else is writing it");
}

/* ------------------------------------------------------------------ */

int fmma_selftest_run(struct fmma_fpga *f, struct fmma_selftest_result *out)
{
    struct fmma_selftest_result r;
    memset(&r, 0, sizeof(r));

    struct ctx c;
    memset(&c, 0, sizeof(c));
    c.f = f;
    c.r = &r;

    /* A step comfortably outside the band, so "did it trade?" is not a
     * question about rounding. */
    uint32_t thresh = fmma_fpga_read(f, FMMA_CFG_THRESH);
    if (thresh == 0) thresh = 5;
    c.step = thresh * 4;

    printf("hardware protocol conformance\n\n");

    fmma_fpga_set_enabled(f, 1);
    usleep(SETTLE_US);

    t_liveness(&c);
    t_seqlock_at_rest(&c);
    t_decides(&c);
    t_below_threshold(&c);
    t_host_never_written(&c);
    t_kill_switch(&c);
    t_risk_limit(&c);
    t_restart(&c);

    fmma_fpga_set_enabled(f, 0);

    printf("\n  %u checks, %u passed, %u failed\n", r.run, r.passed, r.failed);
    if (r.failed == 0)
        printf("  the fabric implements protocol v%u as specified\n",
               FMMA_PROTOCOL_VERSION);

    if (out) *out = r;
    return r.failed == 0 ? 0 : 1;
}
