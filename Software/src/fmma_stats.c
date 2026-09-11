#include "fmma_stats.h"
#include "fmma_log.h"
#include "fmma_time.h"

#include <string.h>

#define TAG "stats"

/* Bucket n covers [2^n, 2^(n+1)) microseconds. */
static unsigned bucket_of(uint64_t us)
{
    unsigned b = 0;
    while (us > 1 && b < FMMA_LAT_BUCKETS - 1) { us >>= 1; b++; }
    return b;
}

void fmma_stats_init(struct fmma_stats *s)
{
    memset(s, 0, sizeof(*s));
    s->lat_min = UINT64_MAX;
    s->started_us = fmma_now_us();
    s->last_tick_us = s->started_us;
}

void fmma_stats_tick(struct fmma_stats *s, uint32_t seq)
{
    uint64_t now = fmma_now_us();
    s->tick_time_us[seq % FMMA_TICK_HISTORY] = now;
    s->last_tick_us = now;
    s->ticks++;
}

uint64_t fmma_stats_signal(struct fmma_stats *s, uint32_t seq)
{
    s->signals++;
    uint64_t published = s->tick_time_us[seq % FMMA_TICK_HISTORY];
    if (published == 0) return 0;

    uint64_t now = fmma_now_us();
    if (now < published) return 0;           /* cannot happen; be safe */
    uint64_t dt = now - published;

    s->lat_count++;
    s->lat_sum += dt;
    if (dt < s->lat_min) s->lat_min = dt;
    if (dt > s->lat_max) s->lat_max = dt;
    s->lat_hist[bucket_of(dt)]++;
    return dt;
}

void fmma_stats_software(struct fmma_stats *s, uint64_t ns)
{
    s->sw_count++;
    s->sw_sum += ns;
    if (ns > s->sw_max) s->sw_max = ns;
}

uint64_t fmma_stats_feed_age_us(const struct fmma_stats *s)
{
    uint64_t now = fmma_now_us();
    return now > s->last_tick_us ? now - s->last_tick_us : 0;
}

uint64_t fmma_stats_percentile(const struct fmma_stats *s, double p)
{
    if (s->lat_count == 0) return 0;

    /* At least one sample must be at or below the answer, so round up
     * and never ask for zero: with `want` at 0 the first bucket
     * satisfies the test whether or not anything landed in it. */
    uint64_t want = (uint64_t)(s->lat_count * p + 0.999);
    if (want == 0) want = 1;
    if (want > s->lat_count) want = s->lat_count;

    uint64_t seen = 0;
    for (unsigned b = 0; b < FMMA_LAT_BUCKETS; b++) {
        if (s->lat_hist[b] == 0) continue;
        seen += s->lat_hist[b];
        if (seen >= want) {
            /*
             * The buckets are powers of two, so all this can say is
             * "somewhere in [2^b, 2^(b+1))".  Reporting the upper edge
             * is the conservative reading, but the edge may sit above
             * every sample actually taken - and a percentile above the
             * maximum is nonsense that makes a latency table look
             * wrong.  Clamp it; the bound stays honest either way.
             */
            uint64_t edge = 1ull << (b + 1);
            return edge > s->lat_max ? s->lat_max : edge;
        }
    }
    return s->lat_max;
}

void fmma_stats_report(const struct fmma_stats *s)
{
    uint64_t elapsed = fmma_now_us() - s->started_us;

    fmma_print("\n--- %llu s ---------------------------------------------\n",
               (unsigned long long)(elapsed / 1000000ull));
    fmma_print("  ticks %llu   signals %llu   orders %llu sent / %llu filled"
               " / %llu rejected\n",
               (unsigned long long)s->ticks,
               (unsigned long long)s->signals,
               (unsigned long long)s->orders_sent,
               (unsigned long long)s->orders_filled,
               (unsigned long long)s->orders_rejected);

    if (s->cooldown_drops || s->missed_signals || s->clamped_prices ||
        s->feed_drops || s->errors)
        fmma_print("  cooldown drops %llu   missed signals %llu   "
                   "clamped prices %llu   feed drops %llu   errors %llu\n",
                   (unsigned long long)s->cooldown_drops,
                   (unsigned long long)s->missed_signals,
                   (unsigned long long)s->clamped_prices,
                   (unsigned long long)s->feed_drops,
                   (unsigned long long)s->errors);

    if (s->lat_count) {
        fmma_print("  quote -> decision seen:  min %llu us   mean %llu us   "
                   "p99 %llu us   max %llu us   (n=%llu)\n",
                   (unsigned long long)s->lat_min,
                   (unsigned long long)(s->lat_sum / s->lat_count),
                   (unsigned long long)fmma_stats_percentile(s, 0.99),
                   (unsigned long long)s->lat_max,
                   (unsigned long long)s->lat_count);
    }

    if (s->sw_count) {
        fmma_print("  software strategy:       mean %llu ns   max %llu ns   "
                   "(n=%llu)\n",
                   (unsigned long long)(s->sw_sum / s->sw_count),
                   (unsigned long long)s->sw_max,
                   (unsigned long long)s->sw_count);
    }
}
