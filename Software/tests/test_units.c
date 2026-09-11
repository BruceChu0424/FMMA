/*
 * Host-runnable unit tests for the parts of the HPS application that
 * are pure functions: fixed-point conversion, JSON field extraction,
 * the strategy, and the P&L accounting.
 *
 * These need no board, no network and no root, so they run in the same
 * regression pass as everything else:
 *
 *     make -C Software test
 *
 * The strategy is also tested through the instruction set simulator
 * against the *assembly* implementation (Software/test_strategy.py).
 * Testing it here as well is not duplication: it is what makes
 * --bench's comparison meaningful, because it proves the C version
 * really is the same algorithm.
 */

#include "../src/fmma_fixed.h"
#include "../src/fmma_json.h"
#include "../src/fmma_risk.h"
#include "../src/fmma_strategy.h"
#include "../fmma_protocol.h"

#include <stdio.h>
#include <string.h>

static int g_checks, g_failures;

#define CHECK(cond, ...)                                            \
    do {                                                            \
        g_checks++;                                                 \
        if (!(cond)) {                                              \
            g_failures++;                                           \
            printf("  FAIL %s:%d  ", __FILE__, __LINE__);           \
            printf(__VA_ARGS__);                                    \
            printf("\n");                                           \
        }                                                           \
    } while (0)

#define CHECK_EQ(got, want, what)                                   \
    do {                                                            \
        long long g_ = (long long)(got), w_ = (long long)(want);    \
        CHECK(g_ == w_, "%s: got %lld, want %lld", what, g_, w_);   \
    } while (0)

static void section(const char *name) { printf("\n%s\n", name); }

/* ------------------------------------------------------------------ */

static void test_fixed(void)
{
    section("fixed-point parsing");

    CHECK_EQ(fmma_parse_scaled("97431.02", 100), 9743102, "two decimals");
    CHECK_EQ(fmma_parse_scaled("97431", 100), 9743100, "no decimal point");
    CHECK_EQ(fmma_parse_scaled("0.0013", 10000), 13, "fractional size");
    CHECK_EQ(fmma_parse_scaled("-3.5", 100), -350, "negative");
    CHECK_EQ(fmma_parse_scaled("+1.25", 100), 125, "leading plus");
    CHECK_EQ(fmma_parse_scaled("1.239", 100), 123, "truncates, not rounds");
    CHECK_EQ(fmma_parse_scaled("0", 100), 0, "zero");
    CHECK_EQ(fmma_parse_scaled(".5", 100), FMMA_PARSE_ERROR,
             "leading dot is rejected");
    CHECK_EQ(fmma_parse_scaled("nope", 100), FMMA_PARSE_ERROR, "not a number");
    CHECK_EQ(fmma_parse_scaled(NULL, 100), FMMA_PARSE_ERROR, "null");

    /* Stops at the first character that cannot belong to the number,
     * which is what makes it safe on a pointer into a JSON document. */
    CHECK_EQ(fmma_parse_scaled("97431.02\",\"best_ask\":\"1", 100),
             9743102, "stops at the closing quote");

    /* The precision a float would have lost. */
    CHECK_EQ(fmma_parse_scaled("97431.07", 100), 9743107, "exact cents");

    section("fixed-point formatting");
    char buf[32];
    CHECK(strcmp(fmma_format_scaled(buf, sizeof(buf), 9743102, 100),
                 "97431.02") == 0, "format two decimals: %s", buf);
    CHECK(strcmp(fmma_format_scaled(buf, sizeof(buf), -350, 100),
                 "-3.50") == 0, "format negative: %s", buf);
    CHECK(strcmp(fmma_format_scaled(buf, sizeof(buf), 13, 10000),
                 "0.0013") == 0, "format small: %s", buf);

    section("price clamping");
    int clamped = 0;
    CHECK_EQ(fmma_clamp_price(500000, &clamped), 500000, "in range");
    CHECK_EQ(clamped, 0, "not clamped");
    fmma_clamp_price(FMMA_PRICE_MAX + 1, &clamped);
    CHECK_EQ(clamped, 1, "over range is reported");
    fmma_clamp_price(-1, &clamped);
    CHECK_EQ(clamped, 1, "negative is reported");
}

static void test_json(void)
{
    section("JSON field extraction");

    const char *msg =
        "{\"type\":\"ticker\",\"sequence\":123,\"product_id\":\"BTC-USD\","
        "\"price\":\"97431.07\",\"best_bid\":\"97431.02\","
        "\"best_ask\":\"97431.98\",\"best_bid_size\":\"0.00130000\"}";

    char out[32];
    CHECK_EQ(fmma_json_copy_string(msg, "best_bid", out, sizeof(out)), 0,
             "best_bid found");
    CHECK(strcmp(out, "97431.02") == 0, "best_bid value: %s", out);

    CHECK_EQ(fmma_json_copy_string(msg, "product_id", out, sizeof(out)), 0,
             "product_id found");
    CHECK(strcmp(out, "BTC-USD") == 0, "product_id value: %s", out);

    CHECK_EQ(fmma_json_copy_string(msg, "absent", out, sizeof(out)), -1,
             "missing field");
    CHECK_EQ(fmma_json_copy_string(msg, "sequence", out, sizeof(out)), -1,
             "numeric field is not a string field");

    CHECK(fmma_json_type_is(msg, "ticker"), "type is ticker");
    CHECK(!fmma_json_type_is(msg, "tick"), "prefix does not match");
    CHECK(!fmma_json_type_is(msg, "match"), "wrong type");

    /* The bug this replaced: "last_match" must not look like "match",
     * and the channel list in a subscription ack must not look like a
     * ticker message. */
    const char *lm = "{\"type\":\"last_match\",\"price\":\"1\"}";
    CHECK(!fmma_json_type_is(lm, "match"), "last_match is not match");
    const char *ack =
        "{\"type\":\"subscriptions\",\"channels\":[{\"name\":\"ticker\"}]}";
    CHECK(!fmma_json_type_is(ack, "ticker"), "ack is not a ticker message");

    /* Truncation must fail rather than return a partial value. */
    char tiny[4];
    CHECK_EQ(fmma_json_copy_string(msg, "best_bid", tiny, sizeof(tiny)), -1,
             "value that does not fit is rejected");
}

static void test_strategy(void)
{
    section("strategy");

    struct fmma_strategy s;

    /* first quote only anchors */
    fmma_strategy_init(&s, 1000, 100, 0);
    CHECK_EQ(fmma_strategy_on_quote(&s, 1000000, 1000100), FMMA_SIGNAL_NONE,
             "first quote anchors");

    /* a small move stays inside the band */
    CHECK_EQ(fmma_strategy_on_quote(&s, 999900, 1000000), FMMA_SIGNAL_NONE,
             "small move");

    /* a fall through the band buys */
    fmma_strategy_init(&s, 1000, 100, 0);
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 998000, 998100), FMMA_SIGNAL_BUY,
             "fall -> buy");

    /* a rise through the band sells */
    fmma_strategy_init(&s, 1000, 100, 0);
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 1002000, 1002100), FMMA_SIGNAL_SELL,
             "rise -> sell");

    /* re-anchoring means one move fires once */
    fmma_strategy_init(&s, 1000, 100, 0);
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    fmma_strategy_on_quote(&s, 998000, 998100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 998000, 998100), FMMA_SIGNAL_NONE,
             "same level twice fires once");

    /* one-sided book is ignored */
    fmma_strategy_init(&s, 1000, 100, 0);
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 0, 998100), FMMA_SIGNAL_NONE,
             "no bid");
    CHECK_EQ(fmma_strategy_on_quote(&s, 998000, 0), FMMA_SIGNAL_NONE,
             "no ask");

    section("strategy risk limit");

    /* at the long limit, a buy is blocked and a sell is not */
    fmma_strategy_init(&s, 1000, 2, 2);
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 998000, 998100), FMMA_SIGNAL_NONE,
             "buy blocked at the long limit");
    CHECK_EQ(s.rejects, 1, "rejection counted");
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 1002000, 1002100), FMMA_SIGNAL_SELL,
             "sell still allowed at the long limit");

    /* at the short limit, a sell is blocked and a buy is not */
    fmma_strategy_init(&s, 1000, 2, -2);
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 1002000, 1002100), FMMA_SIGNAL_NONE,
             "sell blocked at the short limit");
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 998000, 998100), FMMA_SIGNAL_BUY,
             "buy still allowed at the short limit");

    /* just inside the limit is allowed */
    fmma_strategy_init(&s, 1000, 3, 2);
    fmma_strategy_on_quote(&s, 1000000, 1000100);
    CHECK_EQ(fmma_strategy_on_quote(&s, 998000, 998100), FMMA_SIGNAL_BUY,
             "just inside the limit");

    /* fills move the position */
    fmma_strategy_init(&s, 1000, 100, 0);
    fmma_strategy_on_fill(&s, FMMA_FILL_BOUGHT, 3);
    CHECK_EQ(s.position, 3, "bought 3");
    fmma_strategy_on_fill(&s, FMMA_FILL_SOLD, 5);
    CHECK_EQ(s.position, -2, "sold 5");
}

static void test_risk(void)
{
    section("P&L accounting");

    struct fmma_risk r;

    /* buy 1 @ 100, sell 1 @ 110 -> +10 */
    fmma_risk_init(&r, 0, 0, 0);
    fmma_risk_on_fill(&r, FMMA_FILL_BOUGHT, 1, 100);
    CHECK_EQ(r.position, 1, "long 1");
    CHECK_EQ(r.avg_price, 100, "average entry");
    fmma_risk_on_fill(&r, FMMA_FILL_SOLD, 1, 110);
    CHECK_EQ(r.position, 0, "flat");
    CHECK_EQ(r.realised, 10, "realised profit");

    /* averaging in: buy 1 @ 100, buy 1 @ 200 -> average 150 */
    fmma_risk_init(&r, 0, 0, 0);
    fmma_risk_on_fill(&r, FMMA_FILL_BOUGHT, 1, 100);
    fmma_risk_on_fill(&r, FMMA_FILL_BOUGHT, 1, 200);
    CHECK_EQ(r.avg_price, 150, "averaged entry");
    CHECK_EQ(r.position, 2, "long 2");

    /* short side: sell 1 @ 100, buy 1 @ 90 -> +10 */
    fmma_risk_init(&r, 0, 0, 0);
    fmma_risk_on_fill(&r, FMMA_FILL_SOLD, 1, 100);
    CHECK_EQ(r.position, -1, "short 1");
    fmma_risk_on_fill(&r, FMMA_FILL_BOUGHT, 1, 90);
    CHECK_EQ(r.realised, 10, "profit on the short");

    /* unrealised marks against the mid */
    fmma_risk_init(&r, 0, 0, 0);
    fmma_risk_on_fill(&r, FMMA_FILL_BOUGHT, 2, 100);
    fmma_risk_mark(&r, 120);
    CHECK_EQ(r.unrealised, 40, "unrealised on 2 lots");
    CHECK_EQ(fmma_risk_pnl(&r), 40, "total P&L");

    section("risk limits");

    /* the loss limit halts */
    fmma_risk_init(&r, 50, 0, 0);
    fmma_risk_on_fill(&r, FMMA_FILL_BOUGHT, 1, 100);
    fmma_risk_mark(&r, 40);                      /* -60, past the limit */
    CHECK_EQ(fmma_risk_check(&r, 0), FMMA_RISK_LOSS_LIMIT, "loss limit hit");
    CHECK(r.halted, "halted after the limit");
    CHECK_EQ(fmma_risk_check(&r, 0), FMMA_RISK_HALTED, "stays halted");

    /* a stale feed blocks, without halting */
    fmma_risk_init(&r, 0, 1000, 0);
    CHECK_EQ(fmma_risk_check(&r, 500000), FMMA_RISK_OK, "fresh feed");
    CHECK_EQ(fmma_risk_check(&r, 2000000), FMMA_RISK_STALE_FEED, "stale feed");
    CHECK(!r.halted, "stale feed does not halt permanently");
    CHECK_EQ(fmma_risk_check(&r, 0), FMMA_RISK_OK, "recovers");
}

int main(void)
{
    printf("FMMA host unit tests\n");

    test_fixed();
    test_json();
    test_strategy();
    test_risk();

    printf("\n%d checks, %d failures\n", g_checks, g_failures);
    if (g_failures == 0) printf("=== unit tests PASSED ===\n");
    else                 printf("=== unit tests FAILED ===\n");
    return g_failures == 0 ? 0 : 1;
}
