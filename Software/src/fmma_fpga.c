#include "fmma_fpga.h"
#include "fmma_log.h"
#include "fmma_time.h"

#include "../fmma_protocol.h"
#include "../fpga_program.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>

#define TAG "fpga"

#define MAP_BYTES  (FMMA_MEM_WORDS * 4u)

struct fmma_fpga {
    volatile uint32_t *regs;
    void              *map;
    int                fd;
    uint32_t           tick_seq;     /* last even value published */
    uint32_t           fill_seq;
    uint32_t           signal_seq;   /* last decision acted on    */
    uint32_t           heartbeat;
};

/*
 * Order the stores.  The bridge window is mapped with O_SYNC so it is
 * device memory and the ARM core will not reorder the accesses itself,
 * but the compiler happily would - and the seqlock is entirely about the
 * order the stores become visible in.
 */
static inline void barrier(void)
{
    __sync_synchronize();
}

/* ---------------------------------------------------------------- */
/* lifecycle                                                          */
/* ---------------------------------------------------------------- */

struct fmma_fpga *fmma_fpga_open(void)
{
    struct fmma_fpga *f = calloc(1, sizeof(*f));
    if (f == NULL) return NULL;
    f->fd = -1;
    f->map = MAP_FAILED;

    f->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (f->fd == -1) {
        FMMA_ERROR(TAG, "cannot open /dev/mem (%s)", strerror(errno));
        FMMA_ERROR(TAG, "run with sudo, or pass --no-fpga for the software path");
        free(f);
        return NULL;
    }

    f->map = mmap(NULL, MAP_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED,
                  f->fd, FMMA_LW_H2F_BASE);
    if (f->map == MAP_FAILED) {
        FMMA_ERROR(TAG, "mmap of 0x%lX failed (%s)",
                   FMMA_LW_H2F_BASE, strerror(errno));
        close(f->fd);
        free(f);
        return NULL;
    }

    f->regs = (volatile uint32_t *)f->map;
    FMMA_INFO(TAG, "shared RAM mapped at 0x%lX, %u words",
              FMMA_LW_H2F_BASE, FMMA_MEM_WORDS);
    return f;
}

void fmma_fpga_close(struct fmma_fpga *f)
{
    if (f == NULL) return;
    if (f->regs) {
        /* Leave the engine unable to trade if we are going away. */
        f->regs[FMMA_CFG_ENABLE] = 0;
        barrier();
    }
    if (f->map != MAP_FAILED) munmap(f->map, MAP_BYTES);
    if (f->fd != -1) close(f->fd);
    free(f);
}

int fmma_fpga_present(const struct fmma_fpga *f)
{
    return f != NULL && f->regs != NULL;
}

uint32_t fmma_fpga_read(struct fmma_fpga *f, unsigned word)
{
    return fmma_fpga_present(f) ? f->regs[word] : 0u;
}

void fmma_fpga_write(struct fmma_fpga *f, unsigned word, uint32_t value)
{
    if (fmma_fpga_present(f)) f->regs[word] = value;
}

/* ---------------------------------------------------------------- */
/* configuration and start-up                                         */
/* ---------------------------------------------------------------- */

void fmma_fpga_push_config(struct fmma_fpga *f,
                           const struct fmma_fpga_config *cfg)
{
    if (!fmma_fpga_present(f) || cfg == NULL) return;
    f->regs[FMMA_CFG_THRESH]       = cfg->threshold;
    f->regs[FMMA_CFG_MAX_POS]      = cfg->max_position;
    f->regs[FMMA_CFG_POSITION]     = (uint32_t)cfg->start_position;
    f->regs[FMMA_CFG_HALF_SPREAD]  = cfg->half_spread;
    f->regs[FMMA_CFG_SKEW]         = cfg->skew;
    barrier();
}

void fmma_fpga_set_enabled(struct fmma_fpga *f, int enabled)
{
    if (!fmma_fpga_present(f)) return;
    barrier();
    f->regs[FMMA_CFG_ENABLE] = enabled ? 1u : 0u;
}

static int write_program(struct fmma_fpga *f)
{
    if (FPGA_PROGRAM_BASE != FMMA_PROGRAM_BASE) {
        FMMA_ERROR(TAG, "program assembled for word %u but the protocol says "
                        "%u - re-run the assembler",
                   FPGA_PROGRAM_BASE, FMMA_PROGRAM_BASE);
        return -1;
    }
    if (FPGA_PROGRAM_BASE + FPGA_PROGRAM_LEN > FMMA_PROGRAM_LIMIT) {
        FMMA_ERROR(TAG, "program is %u words at %u, past the program area "
                        "(ends at %u)",
                   FPGA_PROGRAM_LEN, FPGA_PROGRAM_BASE, FMMA_PROGRAM_LIMIT);
        return -1;
    }

    FMMA_INFO(TAG, "writing %u program words at word %u, entry word last",
              FPGA_PROGRAM_LEN, FPGA_PROGRAM_BASE);

    /* Entry word last: see docs/07 section 7.4. */
    for (unsigned i = 1; i < FPGA_PROGRAM_LEN; i++)
        f->regs[FPGA_PROGRAM_BASE + i] = fpga_program[i];
    barrier();
    f->regs[FPGA_PROGRAM_BASE] = fpga_program[0];
    barrier();

    for (unsigned i = 0; i < FPGA_PROGRAM_LEN; i++) {
        uint32_t got = f->regs[FPGA_PROGRAM_BASE + i];
        if (got != fpga_program[i]) {
            FMMA_ERROR(TAG, "readback mismatch at word %u: wrote 0x%08X, "
                            "read 0x%08X",
                       FPGA_PROGRAM_BASE + i, fpga_program[i], got);
            FMMA_ERROR(TAG, "the bridge window is not the shared RAM, or the "
                            "FPGA is not configured");
            return -1;
        }
    }
    FMMA_INFO(TAG, "program verified");
    return 0;
}

static int wait_for_cpu(struct fmma_fpga *f)
{
    f->regs[FMMA_FW_VERSION] = 0;      /* so a stale value cannot fool us */
    barrier();
    f->regs[FMMA_CFG_RESTART] = 1;

    FMMA_INFO(TAG, "waiting for the CPU");
    uint32_t beat0 = f->regs[FMMA_HEARTBEAT];

    for (int i = 0; i < 50; i++) {     /* up to ~5 s */
        usleep(100000);
        uint32_t version = f->regs[FMMA_FW_VERSION];
        uint32_t beat    = f->regs[FMMA_HEARTBEAT];

        if (version == FMMA_PROTOCOL_VERSION && beat != beat0) {
            f->heartbeat  = beat;
            f->signal_seq = f->regs[FMMA_SIGNAL_SEQ];
            f->fill_seq   = f->regs[FMMA_FILL_SEQ];
            f->tick_seq   = f->regs[FMMA_TICK_SEQ] & ~1u;
            FMMA_INFO(TAG, "CPU running: protocol v%u, heartbeat %u, "
                           "position %d",
                      version, beat, (int32_t)f->regs[FMMA_POSITION]);
            return 0;
        }
        if (version != 0 && version != FMMA_PROTOCOL_VERSION) {
            FMMA_ERROR(TAG, "the CPU reports protocol v%u, this program "
                            "speaks v%u", version, FMMA_PROTOCOL_VERSION);
            FMMA_ERROR(TAG, "rebuild both from the same tree");
            return -1;
        }
        if (beat != beat0 && version == 0 && i > 20) {
            FMMA_ERROR(TAG, "the CPU is alive but will not declare a version");
            FMMA_ERROR(TAG, "its datapath probe failed: the bitstream is older "
                            "than this program. Rebuild and reprogram the FPGA "
                            "(docs/04 section 4.8)");
            return -1;
        }
    }

    FMMA_ERROR(TAG, "no heartbeat");
    FMMA_ERROR(TAG, "  - is output_files/HFTTop.sof programmed?");
    FMMA_ERROR(TAG, "  - if a previous program is wedged, press KEY[0]");
    return -1;
}

int fmma_fpga_load(struct fmma_fpga *f, const struct fmma_fpga_config *cfg)
{
    if (!fmma_fpga_present(f)) return -1;

    FMMA_INFO(TAG, "disabling trading while the image is replaced");
    f->regs[FMMA_CFG_ENABLE]  = 0;
    f->regs[FMMA_CFG_RESTART] = 0;
    fmma_fpga_push_config(f, cfg);

    if (write_program(f) != 0) return -1;
    return wait_for_cpu(f);
}

/* ---------------------------------------------------------------- */
/* runtime protocol                                                   */
/* ---------------------------------------------------------------- */

uint32_t fmma_fpga_publish_tick(struct fmma_fpga *f,
                                uint32_t bid, uint32_t ask,
                                uint32_t bid_size, uint32_t ask_size)
{
    if (!fmma_fpga_present(f)) return 0;

    uint32_t odd = f->tick_seq + 1;
    f->regs[FMMA_TICK_SEQ] = odd;          /* writer in progress */
    barrier();

    f->regs[FMMA_BID]      = bid;
    f->regs[FMMA_ASK]      = ask;
    f->regs[FMMA_BID_SIZE] = bid_size;
    f->regs[FMMA_ASK_SIZE] = ask_size;
    barrier();

    f->tick_seq = odd + 1;                 /* snapshot is stable */
    f->regs[FMMA_TICK_SEQ] = f->tick_seq;
    return f->tick_seq;
}

void fmma_fpga_report_fill(struct fmma_fpga *f, uint32_t side, uint32_t qty)
{
    if (!fmma_fpga_present(f)) return;
    f->regs[FMMA_FILL_SIDE] = side;
    f->regs[FMMA_FILL_QTY]  = qty;
    barrier();
    f->fill_seq++;
    f->regs[FMMA_FILL_SEQ] = f->fill_seq;  /* published last */
}

int fmma_fpga_poll_signal(struct fmma_fpga *f, struct fmma_signal *out)
{
    if (!fmma_fpga_present(f) || out == NULL) return 0;

    uint32_t seq = f->regs[FMMA_SIGNAL_SEQ];
    if (seq == f->signal_seq) return 0;

    /* SIGNAL_SEQ is written after SIGNAL and SIGNAL_TICK, so a new value
     * guarantees the words it describes are already in memory. */
    out->side   = f->regs[FMMA_SIGNAL];
    out->tick   = f->regs[FMMA_SIGNAL_TICK];
    out->seq    = seq;
    out->missed = seq - f->signal_seq - 1;

    f->signal_seq = seq;
    return 1;
}

/* ---------------------------------------------------------------- */
/* observation                                                        */
/* ---------------------------------------------------------------- */

void fmma_fpga_read_state(struct fmma_fpga *f, struct fmma_fpga_state *out)
{
    if (out == NULL) return;
    memset(out, 0, sizeof(*out));
    if (!fmma_fpga_present(f)) return;

    out->heartbeat = f->regs[FMMA_HEARTBEAT];
    out->position  = (int32_t)f->regs[FMMA_POSITION];
    out->status    = f->regs[FMMA_STATUS];
    out->rejects   = f->regs[FMMA_REJECTS];
    out->version   = f->regs[FMMA_FW_VERSION];
    out->quote_bid = f->regs[FMMA_QUOTE_BID];
    out->quote_ask = f->regs[FMMA_QUOTE_ASK];
}

uint32_t fmma_fpga_heartbeat_delta(struct fmma_fpga *f)
{
    if (!fmma_fpga_present(f)) return 0;
    uint32_t beat = f->regs[FMMA_HEARTBEAT];
    uint32_t delta = beat - f->heartbeat;
    f->heartbeat = beat;
    return delta;
}
