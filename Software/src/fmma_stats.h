/*
 * FMMA - counters and latency.
 *
 * The latency this project cares about is "from the moment a quote
 * became visible to the fabric, to the moment this program saw the
 * answer".  Measuring it needs both ends, and the two ends are in
 * different processors, so the fabric tags each decision with the
 * sequence number of the quote that produced it and this module keeps
 * the publish times to subtract from.
 *
 * A mean alone would hide the thing worth showing, so the summary
 * reports min, mean, max and the 99th percentile from a coarse
 * histogram - enough to see a tail without storing every sample.
 */
#ifndef FMMA_STATS_H
#define FMMA_STATS_H

#include <stdint.h>

/* Publish times are kept for this many recent ticks.  Far more than can
 * ever be in flight; the feed produces a handful per second. */
#define FMMA_TICK_HISTORY 256

/* Log-ish buckets from 1 us to ~1 s. */
#define FMMA_LAT_BUCKETS 24

struct fmma_stats {
    /* counters */
    uint64_t ticks, signals, orders_sent, orders_filled;
    uint64_t orders_rejected, cooldown_drops, errors, feed_drops;
    uint64_t missed_signals, clamped_prices;

    /* fabric decision latency, microseconds */
    uint64_t lat_count, lat_sum, lat_min, lat_max;
    uint32_t lat_hist[FMMA_LAT_BUCKETS];

    /* software reference strategy, nanoseconds */
    uint64_t sw_count, sw_sum, sw_max;

    /* when each tick was published, indexed by sequence number */
    uint64_t tick_time_us[FMMA_TICK_HISTORY];

    uint64_t started_us;
    uint64_t last_tick_us;
};

void fmma_stats_init(struct fmma_stats *s);

/* Record that tick `seq` was published now. */
void fmma_stats_tick(struct fmma_stats *s, uint32_t seq);

/*
 * Record a decision that came from tick `seq`.  Returns the measured
 * latency in microseconds, or 0 if the tick is no longer in the window
 * (which only happens if the fabric reports a tick we never published).
 */
uint64_t fmma_stats_signal(struct fmma_stats *s, uint32_t seq);

/* Record one timing of the software reference strategy. */
void fmma_stats_software(struct fmma_stats *s, uint64_t ns);

/* Microseconds since the last published tick - the staleness check. */
uint64_t fmma_stats_feed_age_us(const struct fmma_stats *s);

/* Latency percentile from the histogram, in microseconds. */
uint64_t fmma_stats_percentile(const struct fmma_stats *s, double p);

/* Print the periodic summary. */
void fmma_stats_report(const struct fmma_stats *s);

#endif /* FMMA_STATS_H */
