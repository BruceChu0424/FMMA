#include "fmma_log.h"
#include "fmma_time.h"

#include <stdio.h>

static enum fmma_log_level s_level = FMMA_LOG_INFO;
static uint64_t s_start_us;

static const char *level_name(enum fmma_log_level l)
{
    switch (l) {
    case FMMA_LOG_ERROR: return "ERROR";
    case FMMA_LOG_WARN:  return "WARN ";
    case FMMA_LOG_INFO:  return "info ";
    default:             return "debug";
    }
}

void fmma_log_init(enum fmma_log_level level)
{
    s_level = level;
    s_start_us = fmma_now_us();
    /* Line buffered: a log that is redirected to a file must still be
     * complete if the process is killed mid-run. */
    setvbuf(stdout, NULL, _IOLBF, 0);
}

void fmma_log_set_level(enum fmma_log_level level) { s_level = level; }
enum fmma_log_level fmma_log_get_level(void) { return s_level; }

void fmma_log(enum fmma_log_level level, const char *tag, const char *fmt, ...)
{
    if (level > s_level) return;

    uint64_t dt = fmma_now_us() - s_start_us;
    printf("[%6llu.%03llu] %s %-8s ",
           (unsigned long long)(dt / 1000000ull),
           (unsigned long long)((dt / 1000ull) % 1000ull),
           level_name(level), tag);

    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
    putchar('\n');
}

void fmma_print(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vprintf(fmt, ap);
    va_end(ap);
}
