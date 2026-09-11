/*
 * FMMA - monotonic time.
 *
 * Everything that measures latency uses CLOCK_MONOTONIC, never the wall
 * clock: the wall clock can step backwards (NTP, or a board whose RTC
 * starts at 1970 and is corrected later), and a negative latency in a
 * histogram is worse than no histogram.
 */
#ifndef FMMA_TIME_H
#define FMMA_TIME_H

#include <stdint.h>
#include <time.h>

static inline uint64_t fmma_now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static inline uint64_t fmma_now_us(void)
{
    return fmma_now_ns() / 1000ull;
}

static inline uint64_t fmma_now_ms(void)
{
    return fmma_now_ns() / 1000000ull;
}

#endif /* FMMA_TIME_H */
