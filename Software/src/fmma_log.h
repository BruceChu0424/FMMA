/*
 * FMMA - leveled logging.
 *
 * Line-buffered and timestamped, because the two things you want from a
 * log when a trade goes wrong are "in what order" and "when".  The
 * timestamp is monotonic seconds since the program started, which is what
 * the latency figures are relative to.
 */
#ifndef FMMA_LOG_H
#define FMMA_LOG_H

#include <stdarg.h>

enum fmma_log_level {
    FMMA_LOG_ERROR = 0,
    FMMA_LOG_WARN,
    FMMA_LOG_INFO,
    FMMA_LOG_DEBUG
};

/* Call once at startup. */
void fmma_log_init(enum fmma_log_level level);

void fmma_log_set_level(enum fmma_log_level level);
enum fmma_log_level fmma_log_get_level(void);

void fmma_log(enum fmma_log_level level, const char *tag, const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 3, 4)))
#endif
    ;

#define FMMA_ERROR(tag, ...) fmma_log(FMMA_LOG_ERROR, (tag), __VA_ARGS__)
#define FMMA_WARN(tag, ...)  fmma_log(FMMA_LOG_WARN,  (tag), __VA_ARGS__)
#define FMMA_INFO(tag, ...)  fmma_log(FMMA_LOG_INFO,  (tag), __VA_ARGS__)
#define FMMA_DEBUG(tag, ...) fmma_log(FMMA_LOG_DEBUG, (tag), __VA_ARGS__)

/* Prints without a tag or level prefix - for banners and tables. */
void fmma_print(const char *fmt, ...)
#if defined(__GNUC__)
    __attribute__((format(printf, 1, 2)))
#endif
    ;

#endif /* FMMA_LOG_H */
