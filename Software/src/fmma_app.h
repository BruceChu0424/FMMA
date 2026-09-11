/*
 * FMMA - the application: everything wired together.
 *
 * Keeping the wiring in its own translation unit is what lets every
 * other module stay ignorant of the others.  The feed knows nothing
 * about the FPGA, the FPGA module knows nothing about the broker, and
 * the strategy knows nothing about any of them.  This is the only file
 * that knows the whole shape.
 */
#ifndef FMMA_APP_H
#define FMMA_APP_H

struct fmma_config;

struct fmma_app;

/* Build everything the configuration asks for.  NULL on failure, with
 * the reason already logged. */
struct fmma_app *fmma_app_create(const struct fmma_config *cfg);

/* Run until fmma_app_stop() is called (a signal handler does that). */
int fmma_app_run(struct fmma_app *app);

/* Ask the event loop to exit; safe from a signal handler. */
void fmma_app_stop(void);

void fmma_app_destroy(struct fmma_app *app);

#endif /* FMMA_APP_H */
